import Foundation

/// Offline downloads, chosen the way streaming services size theirs: a quality setting is a budget in
/// gigabytes per hour of video, and the download is the best release that fits it.
///
/// Encore has no server to re-encode video, and re-encoding on the device would take hours of battery
/// for one film. But add-ons usually list many releases of the same title, from multi-gigabyte Blu-ray
/// copies to lean web releases, so the space saving comes from choosing: the sharpest release (up to
/// 1080p, never 4K or an untouched remux) that fits the budget, preferring HEVC and AV1, which are about
/// half the size of H.264 at the same quality.
public enum DownloadQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    /// About 1 GB an hour: a 45-minute episode around 400–700 MB, a film around 1.5–2 GB.
    case standard
    /// About 2.5 GB an hour: sharper on a big screen, roughly twice the space.
    case high

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .standard: "Standard"
        case .high: "Higher"
        }
    }

    public var detail: String {
        switch self {
        case .standard: "Downloads faster and uses less space."
        case .high: "Sharper picture; uses about twice the space."
        }
    }

    /// The most a download may take per hour of video.
    public var bytesPerHour: Double {
        switch self {
        case .standard: 1.1 * 1_073_741_824
        case .high: 2.6 * 1_073_741_824
        }
    }

    public var maxResolution: StreamTraits.Resolution { .hd1080 }
}

/// Picks what to download from the ranked sources of a title or episode.
public enum DownloadPicker {
    public struct Choice: Sendable {
        public var stream: RankedStream
        /// The size the source says it is, if it says.
        public var estimatedBytes: Int64?
        /// Nothing fit the budget; this is the smallest suitable release.
        public var overBudget: Bool
    }

    /// - Parameter runtime: the video's length in seconds when known (TMDB, the add-on); otherwise a
    ///   typical length is assumed (45 minutes for an episode, two hours for a film).
    public static func choose(from ranked: [RankedStream], runtime: TimeInterval?, isEpisode: Bool,
                              quality: DownloadQuality) -> Choice? {
        let hours = max(0.2, (runtime ?? (isEpisode ? 45 * 60 : 120 * 60)) / 3600)
        let budget = quality.bytesPerHour * hours
        // A file over HTTP that starts now: no torrents (they need a streaming server and peers), nothing
        // a debrid service would first have to fetch, no camera recordings, nothing above 1080p, and no
        // untouched Blu-ray copies (tens of gigabytes for no visible gain on a phone or laptop).
        let usable = ranked.filter { candidate in
            let t = candidate.traits
            return candidate.stream.url != nil && !t.isUncached && !t.isCam && !t.isRemux
                && t.resolution <= quality.maxResolution && t.resolution >= .sd
        }
        guard !usable.isEmpty else { return nil }

        let fitting = usable.filter { ($0.traits.sizeBytes.map { Double($0) <= budget }) ?? false }
        if let best = fitting.max(by: { score($0, budget: budget) < score($1, budget: budget) }) {
            return Choice(stream: best, estimatedBytes: best.traits.sizeBytes, overBudget: false)
        }
        // Nothing stated a size within the budget: the smallest release that states one, else the
        // best-ranked one that doesn't (its size is only known once the download starts).
        if let smallest = usable.filter({ $0.traits.sizeBytes != nil }).min(by: { $0.traits.sizeBytes! < $1.traits.sizeBytes! }) {
            return Choice(stream: smallest, estimatedBytes: smallest.traits.sizeBytes, overBudget: true)
        }
        return Choice(stream: usable[0], estimatedBytes: nil, overBudget: true)
    }

    /// Within the budget: sharper first, then the more efficient codec, then the larger file (more
    /// bitrate for the same resolution), then instant over not, then the add-on's own order.
    static func score(_ candidate: RankedStream, budget: Double) -> Double {
        let t = candidate.traits
        var s = Double(t.resolution.rawValue) * 1000
        if t.codec == "HEVC" || t.codec == "AV1" { s += 300 }
        if let size = t.sizeBytes { s += Double(size) / budget * 200 }
        if t.isCached { s += 50 }
        s -= Double(candidate.addonRank % 1000) * 0.1
        return s
    }
}

/// One title or episode saved for offline viewing.
public struct DownloadRecord: Codable, Hashable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable {
        case queued, downloading, paused, finished, failed
    }

    /// The video id: a film's id, or an episode's ("tt…:2:5").
    public var id: String
    public var meta: MetaPreview
    public var video: Video?
    public var quality: DownloadQuality
    public var state: State
    /// The file inside the downloads folder, once there is one.
    public var fileName: String?
    public var sourceURL: URL
    public var headers: [String: String]
    /// What the chosen release was called, so it can be found again if its link expires.
    public var sourceName: String?
    public var resolution: String?
    public var expectedBytes: Int64?
    public var receivedBytes: Int64
    public var addedAt: Date
    public var error: String?

    public init(meta: MetaPreview, video: Video?, quality: DownloadQuality, sourceURL: URL,
                headers: [String: String] = [:], sourceName: String? = nil, resolution: String? = nil,
                expectedBytes: Int64? = nil, addedAt: Date = Date()) {
        self.id = video?.id ?? meta.id
        self.meta = meta; self.video = video; self.quality = quality; self.state = .queued
        self.sourceURL = sourceURL; self.headers = headers; self.sourceName = sourceName
        self.resolution = resolution; self.expectedBytes = expectedBytes; self.receivedBytes = 0
        self.addedAt = addedAt
    }

    public var progress: Double {
        guard let expectedBytes, expectedBytes > 0 else { return 0 }
        return min(1, Double(receivedBytes) / Double(expectedBytes))
    }

    /// "S2, E5 · Title" for an episode, the film's name otherwise.
    public var displayTitle: String {
        guard let video else { return meta.name }
        return [video.episodeLabel, video.title == meta.name ? nil : video.title].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The downloads on this device: a small index next to the files.
public final class DownloadIndex: @unchecked Sendable {
    public let folder: URL
    private let file: JSONFile<[DownloadRecord]>
    private let lock = NSLock()

    public init(folder: URL) {
        self.folder = folder
        file = JSONFile(folder.appendingPathComponent("downloads.json"))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    public func load() -> [DownloadRecord] { lock.withLock { file.load() ?? [] } }

    public func save(_ records: [DownloadRecord]) { lock.withLock { try? file.save(records) } }

    public func url(of record: DownloadRecord) -> URL? {
        record.fileName.map { folder.appendingPathComponent($0) }
    }

    /// The bytes a finished download takes on disk.
    public func bytesOnDisk(_ record: DownloadRecord) -> Int64 {
        guard let url = url(of: record),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }

    /// A file name for a record: its id made safe, with the source's extension (mkv, mp4, ...).
    public static func fileName(for record: DownloadRecord, sourceExtension: String) -> String {
        let safe = record.id.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let ext = sourceExtension.isEmpty || sourceExtension.count > 5 ? "mkv" : sourceExtension.lowercased()
        return String(safe) + "." + ext
    }
}
