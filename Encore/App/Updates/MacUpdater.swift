#if os(macOS)
import AppKit
import CryptoKit
import SwiftUI
import EncoreKit

/// Where releases are published: the repository CI built this app from (Info.plist `EncoreRepository`),
/// so renaming the GitHub repository needs no code change.
enum EncoreRelease {
    static var repository: String {
        let injected = Bundle.main.object(forInfoDictionaryKey: "EncoreRepository") as? String ?? ""
        return injected.isEmpty || injected.hasPrefix("$(") ? "ivanxcc/Encore" : injected
    }
}

/// In-place updates for the Mac app, no Sparkle and no Developer ID needed:
///  1. On every launch, read the latest release's `encore-update.json`.
///  2. If its build is newer, offer it.
///  3. "Update Now" downloads the zipped app, refuses it unless its SHA-256 matches the manifest, unpacks
///     it, and hands a tiny shell script the job of swapping the bundle once Encore has quit, then
///     relaunching. A failed swap restores the previous app.
@MainActor
final class MacUpdater: ObservableObject {
    static let shared = MacUpdater()

    enum State: Equatable {
        case idle
        case available(UpdateManifest)
        case downloading(UpdateManifest, Double)
        case installing(UpdateManifest)
        case failed(UpdateManifest, String)
        case upToDate
    }

    @Published var state: State = .idle
    @Published var isPromptPresented = false

    var installedBuild: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0 }
    var installedVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    /// - Parameter userInitiated: from Settings; reports "up to date" instead of staying silent.
    func check(userInitiated: Bool = false) async {
        guard let manifest = await UpdateManifest.fetchLatest(repository: EncoreRelease.repository) else {
            if userInitiated { state = .upToDate }
            return
        }
        if manifest.isNewer(thanBuild: installedBuild) {
            state = .available(manifest)
            isPromptPresented = true
        } else if userInitiated {
            state = .upToDate
        }
    }

    func install(_ manifest: UpdateManifest) {
        Task {
            do {
                state = .downloading(manifest, 0)
                let archive = try await download(manifest)
                state = .installing(manifest)
                let newApp = try unpack(archive)
                try relaunch(replacingWith: newApp)
            } catch {
                state = .failed(manifest, (error as? UpdateError)?.message ?? error.localizedDescription)
            }
        }
    }

    // MARK: Steps

    struct UpdateError: Error { let message: String }

    /// A plain file download (the system writes it straight to disk on its own thread), then a chunked
    /// SHA-256 check. Progress comes from the download task, so the UI never slows the transfer.
    private func download(_ manifest: UpdateManifest) async throws -> URL {
        let delegate = DownloadProgress { [weak self] fraction in
            Task { @MainActor in
                guard let self, case .downloading = self.state else { return }
                self.state = .downloading(manifest, fraction)
            }
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60        // stalls longer than this fail
        config.timeoutIntervalForResource = 60 * 60  // a slow connection still finishes
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (temporary, response) = try await session.download(from: manifest.url, delegate: delegate)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError(message: "The download is not available.") }

        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("Encore-update-\(manifest.build).zip")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)

        let digest = try await Task.detached(priority: .userInitiated) { try Self.sha256(of: destination) }.value
        guard digest == manifest.sha256.lowercased() else {
            try? FileManager.default.removeItem(at: destination)
            throw UpdateError(message: "The download did not match the published checksum, so it was discarded.")
        }
        return destination
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func unpack(_ archive: URL) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Encore-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, folder.path])
        let app = folder.appendingPathComponent("Encore.app")
        guard FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/Encore").path) else {
            throw UpdateError(message: "The update did not contain the Encore app.")
        }
        try? run("/usr/bin/xattr", ["-cr", app.path])
        return app
    }

    /// Install the new app over this one, then relaunch it.
    ///
    /// The swap replaces the bundle's *contents* (Encore.app/Contents), so it only needs write access to
    /// Encore.app itself, which the person who dragged it into Applications owns; /Applications being
    /// root-owned doesn't matter. If even that isn't writable (installed by another user, or by sudo),
    /// macOS asks for an administrator password once and the bundle is handed back to this user so
    /// later updates are silent again.
    private func relaunch(replacingWith newApp: URL) throws {
        let target = Self.installedLocation()
        let script = """
        set -e
        target=\(Self.quoted(target.path))
        new=\(Self.quoted(newApp.path))
        rm -rf "$target/.Contents-new" "$target/.Contents-old"
        /usr/bin/ditto "$new/Contents" "$target/.Contents-new"
        mv "$target/Contents" "$target/.Contents-old"
        if mv "$target/.Contents-new" "$target/Contents"; then
          rm -rf "$target/.Contents-old"
        else
          mv "$target/.Contents-old" "$target/Contents"; exit 1
        fi
        /usr/bin/xattr -cr "$target" 2>/dev/null || true
        /usr/bin/touch "$target"
        """
        let writable = FileManager.default.isWritableFile(atPath: target.path)
            && FileManager.default.isWritableFile(atPath: target.appendingPathComponent("Contents").path)
        if !(writable && (try? run("/bin/sh", ["-c", script])) != nil) {
            let owner = "\(getuid()):\(getgid())"
            let privileged = script + "\nchown -R \(owner) \"$target\"\n"
            let source = "do shell script \(Self.appleScriptString(privileged)) with administrator privileges"
            var error: NSDictionary?
            guard NSAppleScript(source: source)?.executeAndReturnError(&error) != nil else {
                let detail = error?[NSAppleScript.errorMessage] as? String ?? ""
                throw UpdateError(message: "Encore couldn't replace \(target.path). If macOS asked whether Encore may modify apps, allow it in System Settings › Privacy & Security › App Management, then try again. \(detail)")
            }
        }
        // Reopen once this process has exited (the old binary keeps running until then).
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \(Self.quoted(target.path))"]
        try relaunch.run()
        NSApp.terminate(nil)
    }

    /// Where Encore is really installed. An app opened with "Open Anyway" after a browser download can
    /// run from a read-only randomized copy (App Translocation); this resolves it back to the original.
    static func installedLocation() -> URL {
        let running = Bundle.main.bundleURL
        guard running.path.contains("/AppTranslocation/") else { return running }
        typealias Original = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        if let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW),
           let symbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL") {
            let original = unsafeBitCast(symbol, to: Original.self)
            if let url = original(running as CFURL, nil)?.takeRetainedValue() as URL? { return url }
        }
        return URL(fileURLWithPath: "/Applications/Encore.app")
    }

    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    @discardableResult
    private func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError(message: "Unpacking the update failed.") }
        return process.terminationStatus
    }
}

/// Reports download progress from the URLSession delegate queue.
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let report: @Sendable (Double) -> Void
    private var lastReported = -1.0

    init(report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        guard fraction - lastReported >= 0.01 || fraction >= 1 else { return }
        lastReported = fraction
        report(fraction)
    }

    // The async download(from:delegate:) call delivers the file; nothing to do here.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

/// The launch popup.
struct UpdatePromptView: View {
    @ObservedObject var updater: MacUpdater
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title2.weight(.bold))
                    Text("You have \(updater.installedVersion) (build \(updater.installedBuild)).")
                        .foregroundStyle(.secondary)
                }
            }
            if let notes = manifest?.notes, !notes.isEmpty {
                ScrollView {
                    Text(notes).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(maxHeight: 220)
                .padding(12)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
            status
            HStack {
                Spacer()
                Button("Later") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isBusy)
                Button("Update Now") { if let manifest { updater.install(manifest) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBusy || manifest == nil)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private var manifest: UpdateManifest? {
        switch updater.state {
        case let .available(m), let .downloading(m, _), let .installing(m), let .failed(m, _): m
        default: nil
        }
    }

    private var title: String { "Encore \(manifest?.version ?? "") (build \(manifest?.build ?? 0)) is available" }

    private var isBusy: Bool {
        switch updater.state {
        case .downloading, .installing: true
        default: false
        }
    }

    @ViewBuilder private var status: some View {
        switch updater.state {
        case let .downloading(_, progress):
            ProgressView(value: progress) { Text("Downloading…") }
        case .installing:
            ProgressView { Text("Installing. Encore will reopen in a moment.") }
        case let .failed(_, message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        default:
            EmptyView()
        }
    }
}
#endif
