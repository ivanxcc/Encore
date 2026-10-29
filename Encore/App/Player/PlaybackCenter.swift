import SwiftUI
import EncoreKit

/// What the viewer asked to watch.
struct PlaybackRequest: Identifiable {
    let id = UUID()
    let meta: MetaPreview
    /// Episode (series) or nil (movie).
    let video: Video?
    let resumeAt: TimeInterval
    /// A source the viewer picked by hand. When set, only it is tried (engines may still fall back).
    let explicit: RankedStream?
    /// A downloaded copy on this device: played from disk, no network needed.
    var localFile: URL? = nil

    var videoID: String { video?.id ?? meta.id }
    var displayTitle: String {
        if let video, let label = video.episodeLabel { return "\(meta.name) · \(label)" }
        return meta.name
    }
}

/// Owns the one playback that can be on screen. Screens call `play` / `resume`; the root presents.
@MainActor
final class PlaybackCenter: ObservableObject {
    @Published var request: PlaybackRequest?

    /// - Parameter afterDismissal: true when called from a sheet that is closing. iOS and tvOS refuse to
    ///   present the full-screen player while a sheet is still on screen, so the request waits for it.
    /// - Parameter fromBeginning: start at 0:00 even when the viewer has progress in this video.
    func play(meta: MetaPreview, video: Video?, app: AppModel, explicit: RankedStream? = nil,
              afterDismissal: Bool = false, fromBeginning: Bool = false) {
        let item = app.libraryItem(meta.id)
        // Resume where the viewer left off when they re-open the same video.
        let resume: TimeInterval
        if !fromBeginning, let item, item.isInProgress,
           item.state.videoID == (video?.id ?? meta.id) || (video == nil && item.state.videoID == nil) {
            resume = TimeInterval(item.state.timeOffset) / 1000
        } else {
            resume = 0
        }
        var next = PlaybackRequest(meta: meta, video: video, resumeAt: resume, explicit: explicit)
        // A downloaded copy plays instead of streaming (unless a source was picked by hand).
        if explicit == nil { next.localFile = Self.downloaded(next.videoID) }
        guard afterDismissal else { request = next; return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            request = next
        }
    }

    func resume(_ item: StremioLibraryItem, app: AppModel) {
        let video = item.state.videoID.flatMap { id -> Video? in
            guard id != item.id else { return nil }
            let parts = id.split(separator: ":")
            return Video(id: id, title: item.name,
                         season: parts.count == 3 ? Int(parts[1]) : nil,
                         episode: parts.count == 3 ? Int(parts[2]) : nil)
        }
        var next = PlaybackRequest(meta: item.preview, video: video,
                                   resumeAt: TimeInterval(item.state.timeOffset) / 1000, explicit: nil)
        next.localFile = Self.downloaded(next.videoID)
        request = next
    }

    /// Play a download from the Downloads page.
    func playDownload(_ record: DownloadRecord, app: AppModel) {
        play(meta: record.meta, video: record.video, app: app)
    }

    private static func downloaded(_ videoID: String) -> URL? {
        #if os(tvOS)
        return nil
        #else
        return DownloadManager.shared.localFile(videoID)
        #endif
    }
}

extension View {
    /// Full screen on iPhone/iPad/Apple TV; on the Mac, the player fills the window above everything.
    func playerPresentation(_ center: PlaybackCenter) -> some View {
        modifier(PlayerPresentation(center: center))
    }
}

private struct PlayerPresentation: ViewModifier {
    @ObservedObject var center: PlaybackCenter

    func body(content: Content) -> some View {
        #if os(macOS)
        content.overlay {
            if let request = center.request {
                PlayerScreen(request: request) { center.request = nil }
                    .transition(.opacity)
            }
        }
        .animation(Theme.Motion.content, value: center.request?.id)
        #else
        content.fullScreenCover(item: $center.request) { request in
            PlayerScreen(request: request) { center.request = nil }
        }
        #endif
    }
}
