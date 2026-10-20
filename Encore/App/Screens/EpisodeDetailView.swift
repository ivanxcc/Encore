import SwiftUI
import EncoreKit

/// One episode, as a page of its own in the Apple TV style: the episode's still fills the screen, and
/// its details and the choices that matter (Play or Resume, Play from Beginning, Choose Source) sit low
/// on the left, all on one screen, so there is nothing to scroll past to reach Play.
struct EpisodeDetailView: View {
    let meta: MetaDetail
    let video: Video
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var playback: PlaybackCenter
    @State private var showSources = false
    @FocusState private var focus: Focus?

    enum Focus: Hashable { case play }

    var body: some View {
        let _ = app.libraryRevision
        let item = app.libraryItem(meta.id)
        let progress = item.flatMap { $0.state.videoID == video.id && $0.isInProgress ? $0.progress : nil }
        GeometryReader { screen in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    Spacer(minLength: 0)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(meta.name.uppercased())
                            .font(Theme.Fonts.meta.weight(.semibold))
                            .foregroundStyle(Theme.Colors.secondary)
                        Text(video.title.isEmpty ? (video.episodeLabel ?? meta.name) : video.title)
                            .font(Theme.Fonts.heroTitle)
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.6)
                            .shadow(color: .black.opacity(0.4), radius: 12)
                        MetaLine(parts: [seasonEpisodeText, releaseText])
                    }
                    if let overview = video.overview, !overview.isEmpty {
                        Text(overview)
                            .font(Theme.Fonts.body)
                            .foregroundStyle(Theme.Colors.secondary)
                            .lineLimit(5)
                            .frame(maxWidth: Theme.Metrics.landscapeWidth * 2.6, alignment: .leading)
                    }
                    if let progress {
                        ProgressBar(value: progress).frame(width: 220)
                    }
                    HStack(spacing: 18) {
                        Button {
                            playback.play(meta: meta.preview, video: video, app: app)
                        } label: {
                            Label(progress == nil ? "Play" : "Resume", systemImage: "play.fill")
                        }
                        .pillButtonStyle(.primary)
                        .focused($focus, equals: .play)

                        if progress != nil {
                            Button {
                                playback.play(meta: meta.preview, video: video, app: app, fromBeginning: true)
                            } label: {
                                Label("Play from Beginning", systemImage: "arrow.counterclockwise")
                            }
                            .pillButtonStyle(.secondary)
                        }

                        Button { showSources = true } label: {
                            Label("Choose Source", systemImage: "list.bullet")
                        }
                        .pillButtonStyle(.secondary)
                    }
                    .disabled(isUpcoming)
                    .tvFocusSection()
                }
                .padding(.horizontal, Theme.Metrics.edge)
                .padding(.bottom, bottomPadding)
                .frame(minHeight: screen.size.height, alignment: .bottomLeading)
            }
            .scrollClipDisabled()
            .background {
                // The still, softened behind the text; the show's own artwork when there is no still.
                DetailBackdrop(url: video.thumbnail ?? meta.backdropURL, soften: video.thumbnail == nil ? 0 : 0.25)
            }
        }
        #if os(tvOS)
        .ignoresSafeArea()
        #else
        .ignoresSafeArea(edges: .top)
        #endif
        .encoreCanvas()
        .revealWhenLaidOut()
        .defaultFocus($focus, .play)
        .sheet(isPresented: $showSources) {
            SourcesView(meta: meta.preview, video: video) { ranked in
                showSources = false
                playback.play(meta: meta.preview, video: video, app: app, explicit: ranked, afterDismissal: true)
            }
        }
    }

    private var isUpcoming: Bool { (video.released ?? .distantPast) > Date() }

    private var seasonEpisodeText: String? {
        guard let season = video.season, let episode = video.episode else { return nil }
        return season == 0 ? "Special \(episode)" : "Season \(season) · Episode \(episode)"
    }

    private var releaseText: String? {
        guard let released = video.released else { return nil }
        let date = released.formatted(date: .long, time: .omitted)
        return isUpcoming ? "Coming \(date)" : date
    }

    private var bottomPadding: CGFloat {
        #if os(tvOS)
        return 90
        #else
        return 40
        #endif
    }
}
