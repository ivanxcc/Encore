#if os(macOS)
import AppKit
import CryptoKit
import SwiftUI
import EncoreKit

/// Where releases are published: the repository CI built this app from (Info.plist `EncoreRepository`),
/// so renaming the GitHub repository needs no code change.
enum EncoreRelease {
    /// The channel this build was released on (Info.plist `EncoreChannel`).
    static var builtChannel: UpdateManifest.Channel {
        UpdateManifest.Channel(rawValue: Bundle.main.object(forInfoDictionaryKey: "EncoreChannel") as? String ?? "") ?? .stable
    }

    static var repository: String {
        let injected = Bundle.main.object(forInfoDictionaryKey: "EncoreRepository") as? String ?? ""
        return injected.isEmpty || injected.hasPrefix("$(") ? "ivanxcc/Encore" : injected
    }
}

/// In-place updates for the Mac app, built the way Sparkle does it (no Developer ID needed):
///
///  1. On launch, read the latest release's `encore-update.json`; offer it if its build is newer.
///  2. Download it with a plain download task, verify its SHA-256, and unpack it into
///     ~/Library/Application Support/Encore/Updates. All of this runs off the main thread.
///  3. Hand a small installer script the staged app, then quit. The installer waits for Encore to
///     exit, swaps the bundle (asking for an administrator password only if the folder needs it), clears
///     quarantine, and reopens Encore. The app never modifies itself while it is running.
///  4. Every step is logged to ~/Library/Logs/Encore/Updater.log. If the swap fails, the old app is put
///     back and reopened, and on launch Encore shows why.
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
    /// The outcome of the update that ran while Encore was closed, shown once after relaunch.
    @Published var previousResult: String?

    /// The channel this install follows: what the person chose in Settings, or else the channel the
    /// build was released on (a beta build keeps getting betas).
    var channel: UpdateManifest.Channel {
        get {
            if let raw = UserDefaults.standard.string(forKey: Self.channelKey), let chosen = UpdateManifest.Channel(rawValue: raw) {
                return chosen
            }
            return EncoreRelease.builtChannel
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.channelKey)
        }
    }
    private static let channelKey = "updates.channel"

    var installedBuild: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0 }
    var installedVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    nonisolated static let workDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Encore/Updates", isDirectory: true)
    nonisolated static let logFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Encore/Updater.log")
    nonisolated private static let resultFile = workDirectory.appendingPathComponent("result.txt")

    /// - Parameter userInitiated: from Settings; reports "up to date" instead of staying silent.
    func check(userInitiated: Bool = false) async {
        if !userInitiated { readPreviousResult() }
        guard let manifest = await UpdateManifest.fetchLatest(repository: EncoreRelease.repository, channel: channel) else {
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
                log("Updating from build \(installedBuild) to \(manifest.build) (\(manifest.url.absoluteString))")
                let archive = try await download(manifest)
                state = .installing(manifest)
                let staged = try await Task.detached(priority: .userInitiated) { try await Self.stage(archive, build: manifest.build) }.value
                try launchInstaller(staged: staged, build: manifest.build)
                log("Installer started; quitting so it can replace the app")
                NSApp.terminate(nil)
            } catch {
                let message = (error as? UpdateError)?.message ?? error.localizedDescription
                log("Update failed: \(message)")
                state = .failed(manifest, message)
            }
        }
    }

    // MARK: Download

    struct UpdateError: Error { let message: String }

    private func download(_ manifest: UpdateManifest) async throws -> URL {
        try? FileManager.default.createDirectory(at: Self.workDirectory, withIntermediateDirectories: true)
        let destination = Self.workDirectory.appendingPathComponent("Encore-\(manifest.build).zip")
        let downloader = Downloader(destination: destination) { [weak self] fraction in
            Task { @MainActor in
                guard let self, case .downloading = self.state else { return }
                self.state = .downloading(manifest, fraction)
            }
        }
        try await downloader.run(manifest.url)
        let digest = try await Task.detached(priority: .userInitiated) { try Self.sha256(of: destination) }.value
        guard digest == manifest.sha256.lowercased() else {
            try? FileManager.default.removeItem(at: destination)
            throw UpdateError(message: "The download did not match the published checksum, so it was discarded.")
        }
        log("Downloaded and verified \(destination.lastPathComponent)")
        return destination
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Stage

    /// Unpack the update next to the work directory and check it is really Encore.
    nonisolated private static func stage(_ archive: URL, build: Int) async throws -> URL {
        let folder = workDirectory.appendingPathComponent("staged-\(build)", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await runTool("/usr/bin/ditto", ["-x", "-k", archive.path, folder.path], failure: "Unpacking the update failed.")
        let app = folder.appendingPathComponent("Encore.app")
        guard let bundle = Bundle(url: app),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/Encore").path) else {
            throw UpdateError(message: "The update did not contain the Encore app.")
        }
        try? await runTool("/usr/bin/xattr", ["-cr", app.path], failure: "")
        try? FileManager.default.removeItem(at: archive)
        return app
    }

    /// Run a command line tool without blocking any thread while it runs.
    nonisolated private static func runTool(_ tool: String, _ arguments: [String], failure: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                if finished.terminationStatus == 0 { continuation.resume() }
                else { continuation.resume(throwing: UpdateError(message: failure)) }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    // MARK: Install

    /// Write the installer script and start it. It outlives Encore: it waits for this process to exit.
    private func launchInstaller(staged: URL, build: Int) throws {
        let target = Self.installedLocation()
        let script = Self.workDirectory.appendingPathComponent("install.sh")
        try Self.installerScript.write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.createDirectory(at: Self.logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: Self.resultFile)
        log("Installing \(staged.path) over \(target.path)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), staged.path, target.path,
                             Self.logFile.path, Self.resultFile.path, String(build)]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// Arguments: <pid> <staged app> <installed app> <log> <result file> <build>
    private static let installerScript = #"""
    #!/bin/bash
    PID="$1"; STAGED="$2"; TARGET="$3"; LOG="$4"; RESULT="$5"; BUILD="$6"
    exec >>"$LOG" 2>&1
    echo "[$(date '+%F %T')] installer: waiting for Encore ($PID) to quit"

    for _ in $(seq 1 150); do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
    if kill -0 "$PID" 2>/dev/null; then echo "Encore did not quit; stopping it"; kill -9 "$PID"; sleep 1; fi

    PARENT="$(dirname "$TARGET")"
    NEW="$PARENT/.Encore-$BUILD-new-$$.app"
    OLD="$PARENT/.Encore-previous-$$.app"
    rm -rf "$PARENT"/.Encore-*-new-*.app "$PARENT"/.Encore-previous-*.app 2>/dev/null   # leftovers, best effort

    # Copy next to the old app, then swap with two renames (same folder, so each is atomic).
    # If the second rename fails the previous app is put back. A retry first restores the previous
    # app if an earlier attempt left it aside, so it is never deleted.
    SWAP="{ [ -e '$TARGET' ] || mv '$OLD' '$TARGET'; } && rm -rf '$NEW' && /usr/bin/ditto '$STAGED' '$NEW' && mv '$TARGET' '$OLD' && { mv '$NEW' '$TARGET' || { mv '$OLD' '$TARGET'; false; }; } && { rm -rf '$OLD' 2>/dev/null; true; }"

    if [ -w "$PARENT" ] && /bin/bash -c "$SWAP"; then
      echo "swapped as $(id -un)"
    else
      echo "needs an administrator; asking"
      CMD="$SWAP && /usr/sbin/chown -R $(id -u):$(id -g) '$TARGET'"
      ESCAPED="${CMD//\\/\\\\}"; ESCAPED="${ESCAPED//\"/\\\"}"
      if /usr/bin/osascript -e "do shell script \"$ESCAPED\" with administrator privileges with prompt \"Encore wants to install an update.\""; then
        echo "swapped as administrator"
      else
        echo "FAILED: could not replace $TARGET"
        echo "Encore couldn't replace itself at $TARGET. The previous version is still installed. Details are in ~/Library/Logs/Encore/Updater.log." > "$RESULT"
        [ -d "$TARGET" ] || { [ -d "$OLD" ] && mv "$OLD" "$TARGET"; }
        /usr/bin/open "$TARGET"
        exit 1
      fi
    fi

    /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
    rm -rf "$(dirname "$STAGED")"
    echo "updated:$BUILD" > "$RESULT"
    echo "[$(date '+%F %T')] installer: done, reopening"
    /usr/bin/open "$TARGET"
    """#

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

    // MARK: After relaunch

    private func readPreviousResult() {
        guard let text = try? String(contentsOf: Self.resultFile, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: Self.resultFile)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("updated:") {
            log("Relaunched as build \(installedBuild)")
        } else if !trimmed.isEmpty {
            previousResult = trimmed
        }
    }

    private func log(_ message: String) {
        let line = "[\(Date().formatted(.iso8601))] app: \(message)\n"
        try? FileManager.default.createDirectory(at: Self.logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: Self.logFile) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: Self.logFile)
        }
    }
}

/// A classic delegate-based download task: the file is written by the system, progress arrives as it
/// downloads, and the finished file is moved into place before the system deletes it.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let report: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var moveError: Error?
    private var lastReported = -1.0

    init(destination: URL, report: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.report = report
    }

    func run(_ url: URL) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60        // a stall longer than this fails
        config.timeoutIntervalForResource = 60 * 60  // a slow connection still finishes
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        guard fraction - lastReported >= 0.01 || fraction >= 1 else { return }
        lastReported = fraction
        report(fraction)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, status != 200 {
            moveError = MacUpdater.UpdateError(message: "The download is not available (HTTP \(status)).")
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result = error ?? moveError
        if let result { continuation?.resume(throwing: result) } else { continuation?.resume() }
        continuation = nil
    }
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

    private var title: String {
        let beta = manifest?.releasePage?.absoluteString.contains("-beta.") == true ? " beta" : ""
        return "Encore \(manifest?.version ?? "")\(beta) (build \(manifest?.build ?? 0)) is available"
    }

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
            ProgressView { Text("Installing. Encore will close and reopen in a moment.") }
        case let .failed(_, message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        default:
            EmptyView()
        }
    }
}
#endif
