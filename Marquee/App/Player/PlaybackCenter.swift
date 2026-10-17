import SwiftUI
import MarqueeKit

/// What the viewer asked to watch.
struct PlaybackRequest: Identifiable {
    let id = UUID()
    let meta: MetaPreview
    /// Episode (series) or nil (movie).
    let video: Video?
    let resumeAt: TimeInterval
    /// A source the viewer picked by hand. When set, only it is tried (engines may still fall back).
    let explicit: RankedStream?

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

    func play(meta: MetaPreview, video: Video?, app: AppModel, explicit: RankedStream? = nil) {
        let item = app.libraryItem(meta.id)
        // Resume where the viewer left off when they re-open the same video.
        let resume: TimeInterval
        if let item, item.isInProgress, item.state.videoID == (video?.id ?? meta.id) || (video == nil && item.state.videoID == nil) {
            resume = TimeInterval(item.state.timeOffset) / 1000
        } else {
            resume = 0
        }
        request = PlaybackRequest(meta: meta, video: video, resumeAt: resume, explicit: explicit)
    }

    func resume(_ item: LibraryItem, app: AppModel) {
        let video = item.state.videoID.flatMap { id -> Video? in
            guard id != item.id else { return nil }
            let parts = id.split(separator: ":")
            return Video(id: id, title: item.name,
                         season: parts.count == 3 ? Int(parts[1]) : nil,
                         episode: parts.count == 3 ? Int(parts[2]) : nil)
        }
        request = PlaybackRequest(meta: item.preview, video: video,
                                  resumeAt: TimeInterval(item.state.timeOffset) / 1000, explicit: nil)
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
