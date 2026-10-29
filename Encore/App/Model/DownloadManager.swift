#if !os(tvOS)
import SwiftUI
import EncoreKit

/// Movies and episodes saved for watching offline (iPhone, iPad, Mac).
///
/// Downloads run in a background URL session, as the big streaming apps' do: they carry on when Encore
/// is in the background or closed, and the system relaunches the app to finish them. The release to
/// download is chosen by `DownloadPicker` to fit the quality setting's size budget. Files live in
/// Encore's own folder, out of iCloud backups, and play through the same player as streams.
@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    /// Settings › Downloads.
    static let qualityKey = "downloadQuality"
    static let cellularKey = "downloadOverCellular"

    @Published private(set) var records: [DownloadRecord] = []
    /// The system calls this once it has delivered every event of a relaunch to finish downloads.
    var backgroundCompletion: (() -> Void)?

    let index: DownloadIndex
    private var session: URLSession!
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var lastPublished: [String: Date] = [:]

    enum DownloadError: LocalizedError {
        case noSource, noSpace(needed: Int64, free: Int64), alreadyDownloaded
        var errorDescription: String? {
            switch self {
            case .noSource:
                "No source could be downloaded. Downloads need an instant (cached) source that isn't a torrent."
            case let .noSpace(needed, free):
                "Not enough space: this needs about \(Self.size(needed)) and \(Self.size(free)) is free."
            case .alreadyDownloaded:
                "This is already downloaded."
            }
        }
        private static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    }

    private override init() {
        index = DownloadIndex(folder: StorageLocation.root.appendingPathComponent("Downloads", isDirectory: true))
        super.init()
        records = index.load()
        excludeFromBackup()
        let config = URLSessionConfiguration.background(withIdentifier: "com.ivanxcc.encore.downloads")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        reconnect()
    }

    var quality: DownloadQuality {
        DownloadQuality(rawValue: UserDefaults.standard.string(forKey: Self.qualityKey) ?? "") ?? .dataSaver
    }

    private var allowsCellular: Bool {
        #if os(iOS)
        UserDefaults.standard.bool(forKey: Self.cellularKey)
        #else
        true
        #endif
    }

    // MARK: Looking up

    func record(_ videoID: String) -> DownloadRecord? { records.first { $0.id == videoID } }

    /// The downloaded file for a film or episode, when it's complete and still on disk.
    func localFile(_ videoID: String) -> URL? {
        guard let record = record(videoID), record.state == .finished, let url = index.url(of: record),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Bytes on disk for a download (the file once finished, what has arrived while in progress).
    func bytes(_ record: DownloadRecord) -> Int64 {
        record.state == .finished ? index.bytesOnDisk(record) : record.receivedBytes
    }

    var totalBytes: Int64 { records.reduce(0) { $0 + bytes($1) } }

    /// Free space on this device, as the system counts it for things the user asked for.
    var freeBytes: Int64 {
        let values = try? index.folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                               .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage { return important }
        return Int64(values?.volumeAvailableCapacity ?? 0)
    }

    var totalCapacity: Int64 {
        Int64((try? index.folder.resourceValues(forKeys: [.volumeTotalCapacityKey]))?.volumeTotalCapacity ?? 0)
    }

    // MARK: Downloading

    /// Choose a release that fits the quality setting and start downloading it.
    /// - Parameter runtime: the video's length in seconds, when known, to size the budget exactly.
    func download(meta: MetaPreview, video: Video?, runtime: TimeInterval?, app: AppModel) async throws {
        let id = video?.id ?? meta.id
        if let existing = record(id) {
            if existing.state == .finished { throw DownloadError.alreadyDownloaded }
            remove(id)
        }
        let ranked = await app.session.rankedStreams(type: meta.type, id: id)
        guard let choice = DownloadPicker.choose(from: ranked, runtime: runtime, isEpisode: video != nil, quality: quality),
              let source = PlaybackSource.resolve(choice.stream.stream, streamingServer: nil, title: meta.name)
        else { throw DownloadError.noSource }
        if let needed = choice.estimatedBytes, needed + 500_000_000 > freeBytes {
            throw DownloadError.noSpace(needed: needed, free: freeBytes)
        }
        var record = DownloadRecord(meta: meta, video: video, quality: quality, sourceURL: source.url,
                                    headers: source.headers,
                                    sourceName: choice.stream.stream.title ?? choice.stream.stream.name,
                                    resolution: choice.stream.traits.resolution.label,
                                    expectedBytes: choice.estimatedBytes)
        record.state = .downloading
        records.append(record)
        save()
        start(record)
    }

    private func start(_ record: DownloadRecord, resumeData: Data? = nil) {
        let task: URLSessionDownloadTask
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            var request = URLRequest(url: record.sourceURL)
            for (field, value) in record.headers { request.setValue(value, forHTTPHeaderField: field) }
            request.allowsCellularAccess = allowsCellular
            request.allowsExpensiveNetworkAccess = allowsCellular
            task = session.downloadTask(with: request)
        }
        task.taskDescription = record.id
        tasks[record.id] = task
        update(record.id) { $0.state = .downloading; $0.error = nil }
        task.resume()
    }

    func pause(_ id: String) {
        guard let task = tasks[id] else { return }
        task.cancel { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                if let data { try? data.write(to: self.resumeFile(id)) }
                self.tasks[id] = nil
                self.update(id) { $0.state = .paused }
            }
        }
    }

    func resume(_ id: String) {
        guard let record = record(id) else { return }
        let data = try? Data(contentsOf: resumeFile(id))
        try? FileManager.default.removeItem(at: resumeFile(id))
        start(record, resumeData: data)
    }

    /// A download whose link has gone stale (debrid links expire) starts again from a fresh source.
    func retry(_ id: String, app: AppModel) async throws {
        guard let record = record(id) else { return }
        if (try? Data(contentsOf: resumeFile(id))) != nil {
            resume(id)
        } else {
            remove(id)
            try await download(meta: record.meta, video: record.video, runtime: nil, app: app)
        }
    }

    /// Delete a download, finished or not, and its file.
    func remove(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        if let record = record(id), let url = index.url(of: record) { try? FileManager.default.removeItem(at: url) }
        try? FileManager.default.removeItem(at: resumeFile(id))
        withAnimation(Theme.Motion.content) { records.removeAll { $0.id == id } }
        save()
    }

    func removeAll() {
        for record in records { remove(record.id) }
    }

    // MARK: Bookkeeping

    private func update(_ id: String, _ change: (inout DownloadRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
        save()
    }

    private func save() { index.save(records) }

    private func resumeFile(_ id: String) -> URL {
        index.folder.appendingPathComponent(DownloadIndex.fileName(for: DownloadRecord.placeholder(id), sourceExtension: "resume"))
    }

    /// After a relaunch: pick the running downloads back up; anything that was mid-way without a task
    /// can be resumed by hand.
    private func reconnect() {
        session.getAllTasks { [weak self] running in
            Task { @MainActor in
                guard let self else { return }
                for task in running {
                    guard let id = task.taskDescription, let download = task as? URLSessionDownloadTask else { continue }
                    self.tasks[id] = download
                }
                for record in self.records where record.state == .downloading && self.tasks[record.id] == nil {
                    self.update(record.id) { $0.state = .paused }
                }
            }
        }
    }

    /// Downloads are re-downloadable: they never go into iCloud or computer backups.
    private func excludeFromBackup() {
        var folder = index.folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        MainActor.assumeIsolated {
            // A few updates a second are plenty for a progress ring; every packet would flood the UI.
            let now = Date()
            if let last = lastPublished[id], now.timeIntervalSince(last) < 0.4 { return }
            lastPublished[id] = now
            guard let index = records.firstIndex(where: { $0.id == id }) else { return }
            records[index].receivedBytes = totalBytesWritten
            if totalBytesExpectedToWrite > 0 { records[index].expectedBytes = totalBytesExpectedToWrite }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        // The file must be moved before this returns; the system deletes it afterwards.
        let response = downloadTask.response
        let suggested = response?.suggestedFilename ?? downloadTask.originalRequest?.url?.lastPathComponent ?? ""
        let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? true
        MainActor.assumeIsolated {
            guard let record = record(id) else { return }
            guard ok else {
                update(id) { $0.state = .failed; $0.error = "The source refused the download. Try again for a fresh link." }
                return
            }
            let name = DownloadIndex.fileName(for: record, sourceExtension: (suggested as NSString).pathExtension)
            let target = index.folder.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: target)
            do {
                try FileManager.default.moveItem(at: location, to: target)
                update(id) {
                    $0.fileName = name
                    $0.state = .finished
                    $0.receivedBytes = self.index.bytesOnDisk($0)
                    $0.expectedBytes = $0.receivedBytes
                }
            } catch {
                update(id) { $0.state = .failed; $0.error = "Couldn't save the download: \(error.localizedDescription)" }
            }
            tasks[id] = nil
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription, let error else { return }
        let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        MainActor.assumeIsolated {
            tasks[id] = nil
            guard !cancelled, record(id) != nil else { return }   // paused or removed: handled there
            if let resumeData { try? resumeData.write(to: resumeFile(id)) }
            update(id) {
                $0.state = .failed
                $0.error = (error as NSError).code == NSURLErrorNotConnectedToInternet
                    ? "Waiting for a connection." : error.localizedDescription
            }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            backgroundCompletion?()
            backgroundCompletion = nil
        }
    }
}

private extension DownloadRecord {
    /// Only for naming a file after an id.
    static func placeholder(_ id: String) -> DownloadRecord {
        var record = DownloadRecord(meta: MetaPreview(id: id, type: "movie", name: ""), video: nil, quality: .standard,
                                    sourceURL: URL(fileURLWithPath: "/"))
        record.id = id
        return record
    }
}
#endif
