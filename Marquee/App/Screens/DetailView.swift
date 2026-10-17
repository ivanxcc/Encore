import SwiftUI
import MarqueeKit

@MainActor
final class DetailModel: ObservableObject {
    @Published var meta: MetaDetail?
    @Published var failed = false
    @Published var season: Int = 1

    func load(_ preview: MetaPreview, app: AppModel) async {
        guard meta?.id != preview.id else { return }
        do {
            let detail = try await app.session.addonService.meta(type: preview.type, id: preview.id, in: app.settings.addons)
            meta = detail
            // Open on the season of the episode in progress, else the first real season.
            let progressSeason = app.libraryItem(preview.id)?.state.videoID
                .flatMap { id in detail.videos.first { $0.id == id }?.season }
            season = progressSeason ?? detail.seasons.first ?? 1
        } catch {
            failed = true
        }
    }
}

/// A title page in the Apple TV layout: the backdrop fills the screen, the logo and actions sit low on
/// the left, and episodes and details scroll up over the art.
struct DetailView: View {
    let preview: MetaPreview
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var playback: PlaybackCenter
    @StateObject private var model = DetailModel()
    @State private var showSources = false

    var body: some View {
        let _ = app.libraryRevision
        let libraryItem = app.libraryItem(preview.id)
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: Theme.Metrics.shelfSpacing) {
                header(libraryItem)
                if let meta = model.meta, meta.type == "series" || !meta.seasons.isEmpty {
                    EpisodesSection(meta: meta, season: $model.season, libraryItem: libraryItem) { video in
                        playback.play(meta: meta.preview, video: video, app: app)
                    }
                }
                if let meta = model.meta { AboutSection(meta: meta) }
            }
            .padding(.bottom, 80)
        }
        .ignoresSafeArea(edges: .top)
        .scrollClipDisabled()
        .background {
            Artwork(url: model.meta?.backdropURL ?? preview.backdropURL, maxPixel: 2400)
                .ignoresSafeArea()
                .overlay(Color.black.opacity(0.25))
                .overlay(LinearGradient(colors: [.clear, .black.opacity(0.85), .black],
                                        startPoint: .center, endPoint: .bottom))
        }
        .marqueeCanvas()
        .task(id: preview.id) { await model.load(preview, app: app) }
        .sheet(isPresented: $showSources) {
            SourcesView(meta: model.meta?.preview ?? preview, video: currentVideo(libraryItem))
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
    }

    private var headerHeight: CGFloat {
        #if os(tvOS)
        return 1000
        #elseif os(macOS)
        return 560
        #else
        return 600
        #endif
    }

    @ViewBuilder
    private func header(_ libraryItem: StremioLibraryItem?) -> some View {
        let meta = model.meta
        VStack(alignment: .leading, spacing: 20) {
            Spacer(minLength: 0)
            TitleLogo(logo: meta?.logoURL ?? preview.logoURL, title: meta?.name ?? preview.name, maxWidth: logoWidth)
            MetaLine(parts: metaParts)
            if let description = meta?.description ?? preview.description {
                Text(description)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Colors.secondary)
                    .lineLimit(4)
                    .frame(maxWidth: Theme.Metrics.landscapeWidth * 2.4, alignment: .leading)
            }
            actions(libraryItem)
            if model.failed {
                Label("Details are unavailable right now.", systemImage: "exclamationmark.triangle")
                    .font(Theme.Fonts.meta).foregroundStyle(Theme.Colors.secondary)
            }
        }
        .padding(.horizontal, Theme.Metrics.edge)
        .frame(height: headerHeight, alignment: .bottomLeading)
    }

    private var metaParts: [String?] {
        let meta = model.meta
        let year: String? = meta?.releaseInfo ?? preview.releaseInfo
        let rating: String? = (meta?.imdbRating ?? preview.imdbRating).map { "★ " + $0 }
        let genres: [String]? = meta?.genres ?? preview.genres
        let genreText: String? = genres.map { $0.prefix(3).joined(separator: ", ") }
        return [year, rating, meta?.runtime, genreText]
    }

    private var logoWidth: CGFloat {
        #if os(tvOS)
        return 700
        #else
        return 380
        #endif
    }

    private func currentVideo(_ item: StremioLibraryItem?) -> Video? {
        guard let meta = model.meta else { return nil }
        if let id = item?.state.videoID, let video = meta.videos.first(where: { $0.id == id }) { return video }
        return meta.seasons.first.flatMap { meta.episodes(inSeason: $0).first }
    }

    @ViewBuilder
    private func actions(_ libraryItem: StremioLibraryItem?) -> some View {
        let resuming = libraryItem?.isInProgress == true
        let video = currentVideo(libraryItem)
        HStack(spacing: 18) {
            Button {
                let target = model.meta?.preview ?? preview
                if resuming, let libraryItem {
                    playback.resume(libraryItem, app: app)
                } else {
                    playback.play(meta: target, video: video, app: app)
                }
            } label: {
                Label(playLabel(resuming: resuming, video: video), systemImage: "play.fill")
            }
            .pillButtonStyle(.primary)
            .disabled(model.meta == nil && preview.type == "series")

            Button {
                app.setInList(model.meta?.preview ?? preview, !(libraryItem?.isInLibrary ?? false))
            } label: {
                Image(systemName: libraryItem?.isInLibrary == true ? "checkmark" : "plus")
            }
            .pillButtonStyle(.secondary)
            .accessibilityLabel(libraryItem?.isInLibrary == true ? "Remove from My List" : "Add to My List")

            Button { showSources = true } label: {
                Image(systemName: "list.bullet")
            }
            .pillButtonStyle(.secondary)
            .accessibilityLabel("Choose Source")
        }
        .focusSection()
        if let libraryItem, resuming {
            HStack(spacing: 12) {
                ProgressBar(value: libraryItem.progress).frame(width: 160)
                Text(remaining(libraryItem)).font(Theme.Fonts.meta).foregroundStyle(Theme.Colors.secondary)
            }
        }
    }

    private func playLabel(resuming: Bool, video: Video?) -> String {
        let episode = model.meta?.type == "series" ? video?.episodeLabel.map { " \($0)" } ?? "" : ""
        return (resuming ? "Resume" : "Play") + episode
    }

    private func remaining(_ item: StremioLibraryItem) -> String {
        let minutes = max(1, Int((item.state.duration - item.state.timeOffset) / 60_000))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m left" : "\(minutes)m left"
    }
}

private struct EpisodesSection: View {
    let meta: MetaDetail
    @Binding var season: Int
    let libraryItem: StremioLibraryItem?
    let play: (Video) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(meta.seasons, id: \.self) { number in
                        Button(number == 0 ? "Specials" : "Season \(number)") {
                            withAnimation(Theme.Motion.content) { season = number }
                        }
                        .pillButtonStyle(number == season ? .primary : .secondary)
                    }
                }
                .padding(.horizontal, Theme.Metrics.edge)
                .padding(.vertical, 12)
            }
            .scrollClipDisabled()
            .focusSection()

            Shelf(title: "", items: meta.episodes(inSeason: season)) { video in
                LandscapeCard(image: video.thumbnail ?? meta.backdropURL,
                              title: video.episode.map { "\($0). \(video.title)" } ?? video.title,
                              subtitle: subtitle(video),
                              progress: progress(video)) { play(video) }
            }
        }
    }

    private func subtitle(_ video: Video) -> String? {
        if let released = video.released, released > Date() {
            return "Coming " + released.formatted(date: .abbreviated, time: .omitted)
        }
        return video.overview
    }

    private func progress(_ video: Video) -> Double? {
        guard let item = libraryItem, item.state.videoID == video.id else { return nil }
        return item.progress
    }
}

private struct AboutSection: View {
    let meta: MetaDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("About").font(Theme.Fonts.shelfTitle)
            if let cast = meta.cast, !cast.isEmpty {
                LabeledLine(label: "Starring", value: cast.prefix(6).joined(separator: ", "))
            }
            if let director = meta.director, !director.isEmpty {
                LabeledLine(label: "Director", value: director.joined(separator: ", "))
            }
            if let genres = meta.genres, !genres.isEmpty {
                LabeledLine(label: "Genre", value: genres.joined(separator: ", "))
            }
        }
        .padding(.horizontal, Theme.Metrics.edge)
        .focusable()   // lets the tvOS focus engine scroll down to it
    }
}

private struct LabeledLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(Theme.Fonts.meta).foregroundStyle(Theme.Colors.tertiary).frame(width: 110, alignment: .leading)
            Text(value).font(Theme.Fonts.body).foregroundStyle(Theme.Colors.secondary)
        }
    }
}
