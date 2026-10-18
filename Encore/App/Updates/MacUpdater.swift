#if os(macOS)
import AppKit
import CryptoKit
import SwiftUI
import EncoreKit

/// Where releases are published. GitHub keeps redirecting if the repository is renamed later.
enum EncoreRelease {
    static let repository = "ivanxcc/VortX"
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

    private func download(_ manifest: UpdateManifest) async throws -> URL {
        let (bytes, response) = try await URLSession.shared.bytes(from: manifest.url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError(message: "The download is not available.") }
        let expected = max(response.expectedContentLength, 1)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("Encore-update-\(manifest.build).zip")
        try? FileManager.default.removeItem(at: destination)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var hasher = SHA256()
        var buffer = Data()
        var received: Int64 = 0
        buffer.reserveCapacity(1 << 20)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                hasher.update(data: buffer)
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                state = .downloading(manifest, min(1, Double(received) / Double(expected)))
            }
        }
        hasher.update(data: buffer)
        try handle.write(contentsOf: buffer)
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == manifest.sha256.lowercased() else {
            try? FileManager.default.removeItem(at: destination)
            throw UpdateError(message: "The download did not match the published checksum, so it was discarded.")
        }
        return destination
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

    private func relaunch(replacingWith newApp: URL) throws {
        let current = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
            throw UpdateError(message: "Encore can't replace itself where it is. Move it to the Applications folder, then update again.")
        }
        let backup = current.deletingLastPathComponent().appendingPathComponent(".Encore-previous.app")
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(backup.path)"
        if mv "\(current.path)" "\(backup.path)" && /usr/bin/ditto "\(newApp.path)" "\(current.path)"; then
          rm -rf "\(backup.path)"
        else
          rm -rf "\(current.path)"; mv "\(backup.path)" "\(current.path)"
        fi
        /usr/bin/open "\(current.path)"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try process.run()
        NSApp.terminate(nil)
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
