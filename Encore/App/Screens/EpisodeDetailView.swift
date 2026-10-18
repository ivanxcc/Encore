import SwiftUI
import EncoreKit

/// One episode, Apple TV style: its still full width, the synopsis, and the two choices that matter,
/// Play (or Resume) and Choose Source.
struct EpisodeDetailView: View {
    let meta: MetaDetail
    let video: Video
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var playback: PlaybackCenter
    @Environment(\.dismiss) private var dismiss
    @State private var showSources = false

    var body: some View {
        let _ = app.libraryRevision
        let item = app.libraryItem(meta.id)
        let progress = item.flatMap { $0.state.videoID == video.id && $0.isInProgress ? $0.progress : nil }
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Artwork(url: video.thumbnail ?? meta.backdropURL, maxPixel: 1920)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .bottom) {
                        if let progress {
                            ProgressBar(value: progress).padding(16)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius * 1.5, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    Text(meta.name.uppercased())
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(Theme.Colors.tertiary)
                    Text(video.title.isEmpty ? (video.episodeLabel ?? meta.name) : video.title)
                        .font(Theme.Fonts.heroTitle.weight(.bold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                    MetaLine(parts: [video.episodeLabel, releaseText])
                }

                HStack(spacing: 16) {
                    Button {
                        dismiss()
                        playback.play(meta: meta.preview, video: video, app: app, afterDismissal: true)
                    } label: {
                        Label(progress == nil ? "Play" : "Resume", systemImage: "play.fill")
                    }
                    .pillButtonStyle(.primary)
                    .disabled(isUpcoming)

                    Button { showSources = true } label: {
                        Label("Choose Source", systemImage: "list.bullet")
                    }
                    .pillButtonStyle(.secondary)
                    .disabled(isUpcoming)
                }
                .tvFocusSection()

                if let overview = video.overview, !overview.isEmpty {
                    Text(overview)
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.Colors.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Theme.Metrics.edge)
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
        }
        .encoreCanvas()
        .sheet(isPresented: $showSources) {
            SourcesView(meta: meta.preview, video: video) { ranked in
                showSources = false
                dismiss()
                playback.play(meta: meta.preview, video: video, app: app, explicit: ranked, afterDismissal: true)
            }
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 620)
        .overlay(alignment: .topTrailing) { CloseButton { dismiss() }.padding(16) }
        #endif
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #endif
    }

    private var isUpcoming: Bool { (video.released ?? .distantPast) > Date() }

    private var releaseText: String? {
        guard let released = video.released else { return nil }
        let date = released.formatted(date: .long, time: .omitted)
        return isUpcoming ? "Coming \(date)" : date
    }

    private var maxWidth: CGFloat {
        #if os(tvOS)
        return 1300
        #else
        return 760
        #endif
    }
}
