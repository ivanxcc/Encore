import SwiftUI
import EncoreKit

@MainActor
final class DetailModel: ObservableObject {
    @Published var meta: MetaDetail?
    @Published var extras: TitleExtras?
    @Published var failed = false
    @Published var season: Int = 1
    /// Exact episode lengths for the season on screen (TMDB), by episode number.
    @Published var runtimes: [Int: TimeInterval] = [:]

    func loadRuntimes(app: AppModel) async {
        guard let id = extras?.tmdbId else { return }
        let wanted = season
        let found = await app.episodeRuntimes(tmdbID: id, season: wanted)
        if wanted == season { runtimes = found }
    }

    /// The page's text and buttons are shown once everything they depend on is here, all at once, so
    /// nothing reflows as it arrives (a "Resume" that later becomes "Resume S1, E3", a logo that pops in).
    @Published var ready = false

    /// Titles already fetched this session (and ones prefetched as the pointer passes over them), so a
    /// page reopened, or opened from a hovered card, is complete from its first frame.
    private static var cache: [String: (meta: MetaDetail, extras: TitleExtras?)] = [:]
    private static var inFlight: [String: Task<(meta: MetaDetail, extras: TitleExtras?)?, Never>] = [:]

    /// Fetches a title's details and extras together, once, however many asks there are.
    static func fetch(_ preview: MetaPreview, app: AppModel) async -> (meta: MetaDetail, extras: TitleExtras?)? {
        if let hit = cache[preview.id] { return hit }
        if let running = inFlight[preview.id] { return await running.value }
        let task = Task { @MainActor () -> (meta: MetaDetail, extras: TitleExtras?)? in
            async let extras = app.extras(for: preview)
            guard let detail = try? await app.session.addonService.meta(type: preview.type, id: preview.id, in: app.settings.addons)
            else { _ = await extras; return nil }
            let found = await extras
            // The logo is small and part of the page's first look: decoded before the page shows its details.
            // The full-size artwork is heavy: it starts downloading now and dissolves in when it lands,
            // never holding the page back.
            let backdropURL = DetailView.backdrop(preview: preview, meta: detail, extras: found)
            Task.detached(priority: .utility) { await decode(backdropURL, maxPixel: HeroArtwork.maxPixel) }
            await decode(DetailView.logo(preview: preview, meta: detail, extras: found), maxPixel: HeroArtwork.logoPixel)
            return (detail, found)
        }
        inFlight[preview.id] = task
        let result = await task.value
        inFlight[preview.id] = nil
        if let result { cache[preview.id] = result }
        return result
    }

    private nonisolated static func decode(_ url: URL?, maxPixel: Int) async {
        if let url { _ = await ImagePipeline.shared.image(url, maxPixel: maxPixel) }
    }

    /// Warm the cache for a title the viewer is about to open (hovered, or on the hero).
    static func prefetch(_ preview: MetaPreview, app: AppModel) {
        guard cache[preview.id] == nil, inFlight[preview.id] == nil else { return }
        Task { _ = await fetch(preview, app: app) }
    }

    func load(_ preview: MetaPreview, app: AppModel) async {
        guard meta?.id != preview.id else { ready = true; return }
        // Give a slow add-on a moment, then show what there is rather than nothing.
        let timeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled, !ready { withAnimation(Theme.Motion.content) { ready = true } }
        }
        let result = await Self.fetch(preview, app: app)
        timeout.cancel()
        if let result {
            apply(result, preview: preview, app: app)
        } else {
            failed = true
        }
        withAnimation(.easeOut(duration: 0.35)) { ready = true }
    }

    private func apply(_ result: (meta: MetaDetail, extras: TitleExtras?), preview: MetaPreview, app: AppModel) {
        let detail = result.meta
        meta = detail
        extras = result.extras
        // Open on the season of the episode in progress, else the first real season.
        let videoID = app.libraryItem(preview.id)?.state.videoID
        let progressSeason = videoID.flatMap { id in detail.videos.first { $0.id == id }?.season }
            // Ids from another app may not match this add-on's exactly: "tt…:4:2" still says season 4.
            ?? videoID.flatMap { id -> Int? in
                let parts = id.split(separator: ":")
                guard parts.count == 3, let number = Int(parts[1]), detail.seasons.contains(number) else { return nil }
                return number
            }
        season = progressSeason ?? detail.seasons.first(where: { $0 > 0 }) ?? detail.seasons.first ?? 1
        ready = true
    }
}

/// A title page as the Apple TV app lays one out: the artwork fills the screen edge to edge with the
/// logo, details, and actions low on the left; scrolling down brings up episodes, the cast, and the
/// details over the same artwork, which softens and darkens behind them as they arrive.
struct DetailView: View {
    let preview: MetaPreview
    /// The artwork on screen as the page opened, when it was already decoded at full size (decided once).
    private let heroBackdrop: URL?

    init(preview: MetaPreview) {
        self.preview = preview
        heroBackdrop = preview.backdropURL.flatMap { url in
            ImagePipeline.shared.cached(url, maxPixel: HeroArtwork.maxPixel) != nil ? url : nil
        }
    }
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var playback: PlaybackCenter
    @StateObject private var model = DetailModel()
    @State private var scrolled: CGFloat = 0
    @State private var sourcesFor: SourcesTarget?
    @State private var episodeDetails: Video?
    @State private var trailerID: TrailerID?

    struct TrailerID: Identifiable { let id: String }
    @FocusState private var focus: HeaderFocus?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    enum HeaderFocus: Hashable { case play }

    struct SourcesTarget: Identifiable {
        let video: Video?
        var id: String { video?.id ?? "title" }
    }

    var body: some View {
        let _ = app.libraryRevision
        let libraryItem = app.libraryItem(preview.id)
        GeometryReader { screen in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Theme.Metrics.shelfSpacing) {
                    header(libraryItem, width: screen.size.width)
                        .frame(height: screen.size.height * headerRatio, alignment: isCompact ? .bottom : .bottomLeading)
                    if let meta = model.meta, meta.type == "series" || !meta.seasons.isEmpty {
                        EpisodesSection(meta: meta, season: $model.season, libraryItem: libraryItem, runtimes: model.runtimes,
                                        play: { play($0, fromBeginning: false) },
                                        playFromBeginning: { play($0, fromBeginning: true) },
                                        chooseSource: { sourcesFor = SourcesTarget(video: $0) },
                                        showDetails: { episodeDetails = $0 },
                                        isWatched: { app.isWatched($0.id) },
                                        setWatched: { app.setWatched(meta.preview, video: $0, $1) })
                    }
                    if !cast.isEmpty { CastShelf(people: cast) }
                    if let meta = model.meta { AboutSection(meta: meta, extras: model.extras) }
                }
                .padding(.bottom, 90)
                // The artwork is there from the first frame (it's the one just on screen); the words and
                // buttons arrive together, once, when everything they need has loaded.
                .opacity(model.ready ? 1 : 0)
            }
            .scrollClipDisabled()
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, offset in
                scrolled = offset
            }
            .background {
                DetailBackdrop(url: backdropURL, soften: min(1, max(0, scrolled / (screen.size.height * 0.5))))
            }
        }
        #if os(tvOS)
        .ignoresSafeArea()
        #else
        .ignoresSafeArea(edges: .top)
        #endif
        .encoreCanvas()
        .defaultFocus($focus, .play)
        .task(id: preview.id) { await model.load(preview, app: app) }
        .task(id: "\(model.season)|\(model.extras?.tmdbId ?? 0)") { await model.loadRuntimes(app: app) }
        .navigationDestination(item: $episodeDetails) { video in
            if let meta = model.meta { EpisodeDetailView(meta: meta, video: video).pushedPage() }
        }
        #if os(iOS)
        .fullScreenCover(item: $trailerID) { TrailerView(videoID: $0.id, title: preview.name) }
        #elseif os(macOS)
        .sheet(item: $trailerID) { TrailerView(videoID: $0.id, title: preview.name) }
        #endif
        .sheet(item: $sourcesFor) { target in
            SourcesView(meta: model.meta?.preview ?? preview, video: target.video)
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
    }

    // MARK: Data

    /// The page keeps the exact picture the Home hero was just showing when it is already decoded at
    /// full size, so opening a title is one continuous image instead of one artwork replaced by another
    /// a moment later. Otherwise the sharpest available: TMDB's original once it arrives.
    /// The artwork just on screen when there is one; otherwise none until the details are in, so the page
    /// fades in one picture rather than showing one and swapping it for a sharper one a moment later.
    private var backdropURL: URL? {
        if let heroBackdrop { return heroBackdrop }
        return model.ready ? Self.backdrop(preview: preview, meta: model.meta, extras: model.extras) : nil
    }

    /// The artwork a page shows once its details are in: the one already decoded at full size if any
    /// (the Home hero's), else the sharpest, TMDB's original.
    static func backdrop(preview: MetaPreview, meta: MetaDetail?, extras: TitleExtras?) -> URL? {
        if let shown = preview.backdropURL, ImagePipeline.shared.cached(shown, maxPixel: HeroArtwork.maxPixel) != nil {
            return shown
        }
        return extras?.backdrop ?? preview.backdropURL ?? meta?.backdropURL
    }

    private var logoURL: URL? {
        Self.logo(preview: preview, meta: model.meta, extras: model.extras)
    }

    /// The logo the Home hero was showing when it's already decoded (the same picture carries over),
    /// else the sharpest one: TMDB's, then the add-on's.
    static func logo(preview: MetaPreview, meta: MetaDetail?, extras: TitleExtras?) -> URL? {
        if let shown = preview.logoURL, ImagePipeline.shared.cached(shown, maxPixel: HeroArtwork.logoPixel) != nil {
            return shown
        }
        return extras?.logo ?? preview.logo ?? meta?.logoURL ?? preview.logoURL
    }

    private var cast: [TitleExtras.Person] {
        if let people = model.extras?.cast, !people.isEmpty { return people }
        return TitleExtras.names(model.meta?.cast)
    }

    private var headerRatio: CGFloat {
        #if os(tvOS)
        return 0.92
        #else
        return 0.78
        #endif
    }

    private var trailerAvailable: Bool {
        #if os(tvOS)
        return Trailers.canPlay
        #else
        return true
        #endif
    }

    private func play(_ video: Video, fromBeginning: Bool) {
        playback.play(meta: model.meta?.preview ?? preview, video: video, app: app, fromBeginning: fromBeginning)
    }

    // MARK: Header

    /// iPhone: the Apple TV app's centered title page (a smaller centered logo, centered details and
    /// buttons, the synopsis underneath).
    private var isCompact: Bool {
        #if os(iOS)
        return sizeClass == .compact
        #else
        return false
        #endif
    }

    @ViewBuilder
    private func header(_ libraryItem: StremioLibraryItem?, width: CGFloat) -> some View {
        if isCompact {
            VStack(spacing: 16) {
                Spacer(minLength: 0)
                TitleLogo(logo: logoURL, title: model.meta?.name ?? preview.name,
                          maxWidth: min(width * 0.7, 280), alignment: .bottom)
                CenteredInfoLine(parts: metaParts, ratings: ratingsAndSynopsis.ratings)
                actions(libraryItem)
                if let description = ratingsAndSynopsis.description {
                    Text(description)
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.Colors.secondary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, Theme.Metrics.edge)
            .padding(.bottom, 12)
        } else {
            regularHeader(libraryItem, width: width)
        }
    }

    @ViewBuilder
    private func regularHeader(_ libraryItem: StremioLibraryItem?, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer(minLength: 0)
            TitleLogo(logo: logoURL, title: model.meta?.name ?? preview.name, maxWidth: min(logoWidth, width * 0.55))
            MetaInfoLine(parts: metaParts, ratings: ratingsAndSynopsis.ratings)
            if let tagline = model.extras?.tagline, !tagline.isEmpty, ratingsAndSynopsis.description == nil {
                Text(tagline).font(Theme.Fonts.body).foregroundStyle(Theme.Colors.secondary)
            }
            if let description = ratingsAndSynopsis.description {
                Text(description)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Colors.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: min(Theme.Metrics.landscapeWidth * 2.4, width * 0.6), alignment: .leading)
            }
            actions(libraryItem)
            if model.failed {
                Label("Details are unavailable right now.", systemImage: "exclamationmark.triangle")
                    .font(Theme.Fonts.meta).foregroundStyle(Theme.Colors.secondary)
            }
        }
        .padding(.horizontal, Theme.Metrics.edge)
        .padding(.bottom, 24)
    }

    private var metaParts: [String?] {
        let meta = model.meta
        let year: String? = meta?.releaseInfo ?? preview.releaseInfo
        let genres: [String]? = meta?.genres ?? preview.genres
        let genreText: String? = genres.map { $0.prefix(2).joined(separator: ", ") }
        // A movie's exact length from TMDB reads better than an add-on's rounded "120 min".
        let exact = model.extras?.runtime.map { minutes in
            minutes < 60 ? "\(minutes) min" : minutes % 60 == 0 ? "\(minutes / 60) hr" : "\(minutes / 60) hr \(minutes % 60) min"
        }
        return [year, exact ?? meta?.runtime, genreText, model.extras?.certification]
    }

    /// Ratings lifted out of the add-on's synopsis text, and the synopsis without them.
    private var ratingsAndSynopsis: RatingsExtractor.Result {
        model.meta?.ratingsAndSynopsis ?? preview.ratingsAndSynopsis
    }

    private var logoWidth: CGFloat {
        #if os(tvOS)
        return 700
        #else
        return 380
        #endif
    }

    /// The episode Play means: the one in progress, else the first episode.
    private func currentVideo(_ item: StremioLibraryItem?) -> Video? {
        guard let meta = model.meta else { return nil }
        if let id = item?.state.videoID, let video = meta.videos.first(where: { $0.id == id }) { return video }
        return meta.seasons.first(where: { $0 > 0 }).flatMap { meta.episodes(inSeason: $0).first }
            ?? meta.seasons.first.flatMap { meta.episodes(inSeason: $0).first }
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
                    .frame(maxWidth: isCompact ? 220 : nil)
            }
            .pillButtonStyle(.primary)
            .focused($focus, equals: .play)
            .disabled(model.meta == nil && preview.type == "series")

            Button {
                app.setInList(model.meta?.preview ?? preview, !(libraryItem?.isInLibrary ?? false))
            } label: {
                Image(systemName: libraryItem?.isInLibrary == true ? "checkmark" : "plus")
            }
            .pillButtonStyle(.icon)
            .accessibilityLabel(libraryItem?.isInLibrary == true ? "Remove from My List" : "Add to My List")

            Button { sourcesFor = SourcesTarget(video: video) } label: {
                Image(systemName: "list.bullet")
            }
            .pillButtonStyle(.icon)
            .accessibilityLabel("Choose Source")

            #if !os(tvOS)
            // Save for offline: the film, or the episode the Play button would play.
            if model.meta != nil {
                DownloadButton(meta: model.meta?.preview ?? preview, video: model.meta?.type == "series" ? video : nil,
                               runtime: downloadRuntime(video))
            }
            #endif

            if let trailer = Trailers.youTubeID(extras: model.extras, meta: model.meta), trailerAvailable {
                Button {
                    #if os(tvOS)
                    Trailers.open(trailer)
                    #else
                    trailerID = TrailerID(id: trailer)
                    #endif
                } label: {
                    Image(systemName: "film")
                }
                .pillButtonStyle(.icon)
                .accessibilityLabel("Play Trailer")
            }
        }
        .tvFocusSection()
        if let libraryItem, resuming {
            HStack(spacing: 12) {
                ProgressBar(value: libraryItem.progress).frame(width: 160)
                Text(remaining(libraryItem)).font(Theme.Fonts.meta).foregroundStyle(Theme.Colors.secondary)
            }
        }
    }

    /// The length to size a download by: the episode's exact one, else the title's.
    private func downloadRuntime(_ video: Video?) -> TimeInterval? {
        if model.meta?.type == "series", let episode = video?.episode, let exact = model.runtimes[episode] { return exact }
        if model.meta?.type != "series", let minutes = model.extras?.runtime { return TimeInterval(minutes * 60) }
        return EpisodeCard<EmptyView>.runtime(model.meta?.runtime)
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

/// The page's artwork, fixed behind everything and edge to edge. As the viewer scrolls past the
/// header it dims and softens (a tiny copy of the same image, upscaled, is a free blur), so the rows
/// below read cleanly while staying in the title's colors.
struct DetailBackdrop: View {
    let url: URL?
    /// 0 at the top of the page, 1 once the header has scrolled away.
    var soften: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Artwork(url: url, maxPixel: HeroArtwork.maxPixel, fade: 0.8)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                Artwork(url: url, maxPixel: 48, fade: 0.8)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .opacity(soften)
                LinearGradient(stops: [.init(color: .clear, location: 0.35),
                                       .init(color: Theme.Colors.canvas.opacity(0.85), location: 0.85),
                                       .init(color: Theme.Colors.canvas, location: 1)],
                               startPoint: .top, endPoint: .bottom)
                LinearGradient(stops: [.init(color: .black.opacity(0.7), location: 0), .init(color: .clear, location: 0.6)],
                               startPoint: .leading, endPoint: .trailing)
                Theme.Colors.canvas.opacity(0.55 * soften)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: Episodes

/// Season tabs and the season's episodes. Selecting an episode plays it (resuming where the viewer left
/// off); holding it down offers Play from Beginning, Choose Source, and View Details.
private struct EpisodesSection: View {
    let meta: MetaDetail
    @Binding var season: Int
    let libraryItem: StremioLibraryItem?
    var runtimes: [Int: TimeInterval] = [:]
    let play: (Video) -> Void
    let playFromBeginning: (Video) -> Void
    let chooseSource: (Video) -> Void
    let showDetails: (Video) -> Void
    let isWatched: (Video) -> Bool
    let setWatched: (Video, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if meta.seasons.count > 1 {
                ScrollViewReader { tabs in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(meta.seasons, id: \.self) { number in
                                Button(number == 0 ? "Specials" : "Season \(number)") {
                                    withAnimation(.easeInOut(duration: 0.35)) { season = number }
                                }
                                .pillButtonStyle(.tab(selected: number == season))
                                .id(number)
                            }
                        }
                        .padding(.horizontal, Theme.Metrics.edge)
                        .padding(.vertical, 12)
                    }
                    .scrollClipDisabled()
                    .tvFocusSection()
                    // The season being watched is always in view, not hidden past the screen's edge.
                    .onAppear { tabs.scrollTo(season, anchor: .center) }
                    .onChange(of: season) { _, now in withAnimation(Theme.Motion.content) { tabs.scrollTo(now, anchor: .center) } }
                }
            } else {
                Text("Episodes").font(Theme.Fonts.shelfTitle).padding(.horizontal, Theme.Metrics.edge)
            }

            let episodes = meta.episodes(inSeason: season)
            ZStack(alignment: .topLeading) {
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Theme.Metrics.itemSpacing) {
                        ForEach(episodes) { video in
                            EpisodeCard(meta: meta, video: video, progress: progress(video), remaining: remaining(video),
                                        runtime: video.episode.flatMap { runtimes[$0] },
                                        watched: isWatched(video),
                                        play: { play(video) }) {
                                Button { play(video) } label: {
                                    Label(progress(video) != nil ? "Resume" : "Play", systemImage: "play.fill")
                                }
                                if progress(video) != nil {
                                    Button { playFromBeginning(video) } label: {
                                        Label("Play from Beginning", systemImage: "arrow.counterclockwise")
                                    }
                                }
                                Button { chooseSource(video) } label: { Label("Choose Source", systemImage: "list.bullet") }
                                Button { setWatched(video, !isWatched(video)) } label: {
                                    isWatched(video)
                                        ? Label("Mark as Unwatched", systemImage: "eye.slash")
                                        : Label("Mark as Watched", systemImage: "checkmark.circle")
                                }
                                Button { showDetails(video) } label: { Label("View Details", systemImage: "info.circle") }
                                #if !os(tvOS)
                                EpisodeDownloadMenu(meta: meta.preview, video: video,
                                                    runtime: video.episode.flatMap { runtimes[$0] } ?? EpisodeCard<EmptyView>.runtime(meta.runtime))
                                #endif
                            }
                            .id(video.id)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, Theme.Metrics.edge)
                    #if os(tvOS)
                    .padding(.vertical, 30)
                    #else
                    .padding(.vertical, 6)
                    #endif
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollClipDisabled()
                .tvFocusSection()
                // Open on the episode in progress, not always on episode 1.
                .onAppear { scrollToCurrent(reader, episodes) }
            }
            // Each season is its own row that cross-fades in place, instead of cards sliding in one by one.
            .id(season)
            .transition(.opacity)
            }
        }
    }

    private func scrollToCurrent(_ reader: ScrollViewProxy, _ episodes: [Video]) {
        guard let id = libraryItem?.state.videoID, episodes.contains(where: { $0.id == id }) else { return }
        reader.scrollTo(id, anchor: .leading)
    }

    private func progress(_ video: Video) -> Double? {
        guard let item = libraryItem, item.state.videoID == video.id, item.isInProgress else { return nil }
        return item.progress
    }

    /// Time left in the episode in progress, from the saved position and the length the player saw.
    private func remaining(_ video: Video) -> TimeInterval? {
        guard let item = libraryItem, item.state.videoID == video.id, item.isInProgress, item.state.duration > 0 else { return nil }
        return TimeInterval(item.state.duration - item.state.timeOffset) / 1000
    }
}

/// An episode: its still, then "EPISODE 3", the title, and two lines of synopsis, as on Apple TV.
/// The hold-down menu sits on the focusable card itself, where tvOS looks for it.
private struct EpisodeCard<Menu: View>: View {
    let meta: MetaDetail
    let video: Video
    let progress: Double?
    var remaining: TimeInterval?
    /// The episode's exact length when TMDB knows it; else the show's typical one.
    var runtime: TimeInterval?
    var watched = false
    let play: () -> Void
    @ViewBuilder let menu: () -> Menu

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: play) {
                Artwork(url: video.thumbnail ?? meta.backdropURL, maxPixel: Int(width * 2.5))
                    .frame(width: width, height: width / Theme.Metrics.landscapeAspect)
                    // Apple TV style: what playing it means, low on the still. A check and the length once
                    // watched; a play glyph and the length before; a play glyph, a short bar, and the time
                    // left while in progress.
                    .overlay(alignment: .bottomLeading) {
                        if !isUpcoming { EpisodeStatus(watched: watched, progress: progress, remaining: remaining,
                                                       runtime: runtime ?? Self.runtime(meta.runtime)) }
                    }
                    #if !os(tvOS)
                    .overlay(alignment: .topTrailing) { EpisodeDownloadBadge(videoID: video.id).padding(10) }
                    #endif
                    .overlay {
                        if isUpcoming {
                            Text(comingText).font(Theme.Fonts.cardSubtitle.weight(.semibold))
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .liquidGlass(in: Capsule())
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous))
            }
            .cardButtonStyle()
            .contextMenu { if !isUpcoming { menu() } }
            .disabled(isUpcoming)
            .accessibilityLabel(video.title)
            VStack(alignment: .leading, spacing: 4) {
                if let number = video.episode {
                    Text("EPISODE \(number)")
                        .font(Theme.Fonts.cardSubtitle.weight(.semibold))
                        .foregroundStyle(Theme.Colors.tertiary)
                }
                Text(video.title)
                    .font(Theme.Fonts.cardTitle)
                    .foregroundStyle(Theme.Colors.primary)
                    .lineLimit(1)
                if let overview = video.overview, !overview.isEmpty {
                    Text(overview)
                        .font(Theme.Fonts.cardSubtitle)
                        .foregroundStyle(Theme.Colors.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: width, alignment: .leading)
        }
    }

    private var width: CGFloat { Theme.Metrics.landscapeWidth }

    /// An add-on's runtime ("22 min", "1h 5min", "45") in seconds; episodes share the show's.
    static func runtime(_ text: String?) -> TimeInterval? {
        guard let text = text?.lowercased() else { return nil }
        var minutes = 0
        var number = ""
        for character in text {
            if character.isNumber { number.append(character); continue }
            if character == " " { continue }
            if character == "h", let value = Int(number) { minutes += value * 60 }
            else if character == "m", let value = Int(number) { minutes += value }
            number = ""
            if character == "m" { break }
        }
        if let value = Int(number) { minutes += value }
        return minutes > 0 ? TimeInterval(minutes * 60) : nil
    }
    private var isUpcoming: Bool { (video.released ?? .distantPast) > Date() }
    private var comingText: String {
        "Coming " + (video.released ?? Date()).formatted(.dateTime.month(.abbreviated).day())
    }
}

/// The glass label at the bottom left of an episode's still: ✓ 22m, ▶ 22m, or ▶ ━━── 12m left.
private struct EpisodeStatus: View {
    let watched: Bool
    let progress: Double?
    let remaining: TimeInterval?
    let runtime: TimeInterval?

    var body: some View {
        HStack(spacing: spacing) {
            Image(systemName: progress == nil && watched ? "checkmark" : "play.fill")
                .font(.system(size: size * 0.8, weight: .bold))
            if let progress {
                ProgressBar(value: progress, height: size * 0.3)
                    .frame(width: size * 3)
            }
            if let text = timeText {
                Text(text)
                    .font(.system(size: size, weight: .semibold))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, size * 0.75)
        .padding(.vertical, size * 0.45)
        .liquidGlass(in: Capsule())
        .padding(size * 0.7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var timeText: String? {
        if progress != nil, let remaining { return Self.format(remaining) + " left" }
        return runtime.map(Self.format)
    }

    private var accessibilityText: String {
        let state = progress != nil ? "In progress" : watched ? "Watched" : "Not watched"
        return [state, timeText].compactMap { $0 }.joined(separator: ", ")
    }

    /// 22m, 1h 5m.
    static func format(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    #if os(tvOS)
    private let size: CGFloat = 22
    private let spacing: CGFloat = 10
    #else
    private let size: CGFloat = 12
    private let spacing: CGFloat = 6
    #endif
}

// MARK: Cast

/// "Cast & Crew": round headshots with the name and the role, like the Apple TV app. Without photos
/// (no TMDB key in Encore Cloud) each person gets their initials instead.
private struct CastShelf: View {
    let people: [TitleExtras.Person]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cast & Crew")
                .font(Theme.Fonts.shelfTitle)
                .padding(.horizontal, Theme.Metrics.edge)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.Metrics.itemSpacing) {
                    ForEach(people.prefix(20)) { CastCard(person: $0) }
                }
                .padding(.horizontal, Theme.Metrics.edge)
                #if os(tvOS)
                .padding(.vertical, 24)
                #else
                .padding(.vertical, 6)
                #endif
            }
            .scrollClipDisabled()
            .tvFocusSection()
        }
    }
}

private struct CastCard: View {
    let person: TitleExtras.Person
    #if os(tvOS)
    @FocusState private var focused: Bool
    #endif

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Theme.Colors.placeholder)
                if person.photo != nil {
                    Artwork(url: person.photo, maxPixel: Int(diameter * 2))
                } else {
                    Text(initials).font(.system(size: diameter * 0.32, weight: .semibold)).foregroundStyle(Theme.Colors.secondary)
                }
            }
            .frame(width: diameter, height: diameter)
            .clipShape(Circle())
            .scaleEffect(isFocused ? 1.1 : 1)
            .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 18, y: 10)
            .animation(Theme.Motion.focus, value: isFocused)
            VStack(spacing: 2) {
                Text(person.name).font(Theme.Fonts.cardTitle).foregroundStyle(Theme.Colors.primary).lineLimit(1)
                if let character = person.character, !character.isEmpty {
                    Text(character).font(Theme.Fonts.cardSubtitle).foregroundStyle(Theme.Colors.secondary).lineLimit(1)
                }
            }
            .frame(width: diameter + 40)
        }
        #if os(tvOS)
        .focusable()   // the remote can travel along the cast row, which also scrolls it into view
        .focused($focused)
        #endif
        .accessibilityElement(children: .combine)
    }

    private var isFocused: Bool {
        #if os(tvOS)
        return focused
        #else
        return false
        #endif
    }

    private var initials: String {
        person.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }

    private var diameter: CGFloat {
        #if os(tvOS)
        return 180
        #elseif os(macOS)
        return 96
        #else
        return 84
        #endif
    }
}

// MARK: About

/// The details at the bottom of an Apple TV title page, in quiet columns.
private struct AboutSection: View {
    let meta: MetaDetail
    let extras: TitleExtras?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("About").font(Theme.Fonts.shelfTitle)
            if let description = meta.ratingsAndSynopsis.description {
                Text(description)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Colors.secondary)
                    .frame(maxWidth: Theme.Metrics.landscapeWidth * 3, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: columnWidth), alignment: .topLeading)],
                      alignment: .leading, spacing: 22) {
                ForEach(facts, id: \.0) { label, value in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(label.uppercased())
                            .font(Theme.Fonts.cardSubtitle.weight(.semibold))
                            .foregroundStyle(Theme.Colors.tertiary)
                        Text(value)
                            .font(Theme.Fonts.cardTitle)
                            .foregroundStyle(Theme.Colors.secondary)
                            .lineLimit(3)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Metrics.edge)
        #if os(tvOS)
        .focusable()   // lets the focus engine scroll down to it
        #endif
    }

    private var facts: [(String, String)] {
        var facts: [(String, String)] = []
        if let genres = meta.genres, !genres.isEmpty { facts.append(("Genre", genres.joined(separator: ", "))) }
        if let released = meta.releaseInfo { facts.append(("Released", released)) }
        if let runtime = meta.runtime { facts.append(("Run Time", runtime)) }
        if let rating = extras?.certification { facts.append(("Rated", rating)) }
        let creators = extras?.crew.filter { $0.job == "Creator" }.map(\.name) ?? []
        let directors = extras?.crew.filter { $0.job == "Director" }.map(\.name) ?? meta.director ?? []
        if !creators.isEmpty { facts.append(("Created By", creators.joined(separator: ", "))) }
        if !directors.isEmpty { facts.append(("Directed By", directors.joined(separator: ", "))) }
        return facts
    }

    private var columnWidth: CGFloat {
        #if os(tvOS)
        return 360
        #else
        return 200
        #endif
    }
}

#if !os(tvOS)
/// An episode's download, from its hold-down menu.
private struct EpisodeDownloadMenu: View {
    let meta: MetaPreview
    let video: Video
    let runtime: TimeInterval?
    @ObservedObject private var downloads = DownloadManager.shared
    @EnvironmentObject private var app: AppModel

    var body: some View {
        if let record = downloads.record(video.id) {
            switch record.state {
            case .downloading, .queued:
                Button("Pause Download", systemImage: "pause.fill") { downloads.pause(video.id) }
            case .paused:
                Button("Resume Download", systemImage: "arrow.down") { downloads.resume(video.id) }
            case .failed:
                Button("Try Download Again", systemImage: "arrow.clockwise") { Task { try? await downloads.retry(video.id, app: app) } }
            case .finished:
                EmptyView()
            }
            Button(record.state == .finished ? "Delete Download" : "Cancel Download", systemImage: "trash", role: .destructive) {
                downloads.remove(video.id)
            }
        } else {
            Button("Download Episode", systemImage: "arrow.down.to.line") {
                Task { try? await downloads.download(meta: meta, video: video, runtime: runtime, app: app) }
            }
        }
    }
}

/// On an episode's still: a filled arrow once downloaded, a progress ring while downloading.
private struct EpisodeDownloadBadge: View {
    let videoID: String
    @ObservedObject private var downloads = DownloadManager.shared

    var body: some View {
        if let record = downloads.record(videoID) {
            Group {
                switch record.state {
                case .finished: Image(systemName: "arrow.down.circle.fill").font(.system(size: 14, weight: .semibold))
                case .downloading, .queued: ProgressRing(progress: record.progress, symbol: "arrow.down")
                case .paused: Image(systemName: "pause.circle").font(.system(size: 14, weight: .semibold))
                case .failed: Image(systemName: "exclamationmark.circle").font(.system(size: 14, weight: .semibold))
                }
            }
            .frame(width: 26, height: 26)
            .foregroundStyle(.white)
            .liquidGlass(in: Circle())
            .accessibilityLabel(record.state == .finished ? "Downloaded" : "Downloading")
        }
    }
}
#endif
