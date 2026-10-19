import SwiftUI
import EncoreKit

/// Home, Apple TV style: a full-bleed featured hero, then Continue Watching, then a shelf per catalog.
struct HomeView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var model = HomeModel()

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: Theme.Metrics.shelfSpacing) {
                if !model.featured.isEmpty {
                    HeroCarousel(items: model.featured)
                } else {
                    Color.clear.frame(height: 40)
                }

                if let error = app.syncError {
                    Label(error, systemImage: "icloud.slash")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(Theme.Colors.secondary)
                        .padding(.horizontal, Theme.Metrics.edge)
                }

                ContinueWatchingShelf()

                ForEach(model.shelves) { shelf in
                    if let items = shelf.items {
                        if !items.isEmpty {
                            Shelf(title: shelf.ref.title, items: items) { meta in
                                NavigationLink(value: Route.title(meta)) {
                                    PosterCardLabel(meta: meta)
                                }
                                .cardLinkStyle()
                            }
                        }
                    } else {
                        ShelfPlaceholder(title: shelf.ref.title)
                    }
                }
            }
            .padding(.bottom, 60)
        }
        #if os(tvOS)
        // Edge to edge, like the Apple TV app: the hero runs under the tab bar and past the TV's safe
        // area; shelves keep their own inset.
        .ignoresSafeArea()
        #else
        .ignoresSafeArea(edges: .top)
        #endif
        .scrollClipDisabled()
        .task(id: app.household.id) { model.load(using: app) }
        .onChange(of: app.settings.addons) { _, _ in model.load(using: app) }
        .refreshable {
            await app.refresh()
            model.reload(using: app)
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }
}

/// The poster card as a NavigationLink label (the link supplies the action).
struct PosterCardLabel: View {
    let meta: MetaPreview
    var width: CGFloat = Theme.Metrics.posterWidth

    var body: some View {
        Artwork(url: meta.posterURL, maxPixel: Int(width * 3))
            .frame(width: width, height: width / Theme.Metrics.posterAspect)
            .overlay { if meta.posterURL == nil { TitlePlaceholder(title: meta.name) } }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous))
            .accessibilityLabel(meta.name)
    }
}

extension View {
    /// NavigationLink with the platform card behavior (tvOS focus lift, Mac hover, touch press).
    @ViewBuilder func cardLinkStyle() -> some View {
        cardButtonStyle()
    }
}

/// Continue Watching for the active profile: landscape cards with progress, newest first.
struct ContinueWatchingShelf: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var playback: PlaybackCenter

    var body: some View {
        let items = app.continueWatching()
        let _ = app.libraryRevision   // re-read when progress changes
        if !items.isEmpty {
            Shelf(title: "Continue Watching", items: items) { entry in
                ContinueCard(item: entry.item)
            }
        }
    }
}

private struct ContinueCard: View {
    let item: StremioLibraryItem
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var playback: PlaybackCenter

    var body: some View {
        NavigationLink(value: Route.title(item.preview)) {
            Artwork(url: item.backdropURL, maxPixel: Int(Theme.Metrics.landscapeWidth * 2.5))
                .frame(width: Theme.Metrics.landscapeWidth, height: Theme.Metrics.landscapeWidth / Theme.Metrics.landscapeAspect)
                .bottomScrim(0.7)
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.name).font(Theme.Fonts.cardTitle).foregroundStyle(.white).lineLimit(1)
                        if let episode = Self.episodeLabel(item.state.videoID) {
                            Text(episode).font(Theme.Fonts.cardSubtitle).foregroundStyle(Theme.Colors.secondary)
                        }
                        ProgressBar(value: item.progress)
                    }
                    .padding(14)
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous))
        }
        .cardLinkStyle()
        .contextMenu {
            Button("Resume", systemImage: "play.fill") { playback.resume(item, app: app) }
            Button("Remove from Continue Watching", systemImage: "xmark") { app.dismissContinueWatching(item.id) }
        }
    }

    /// "tt123:2:5" -> "S2, E5".
    static func episodeLabel(_ videoID: String?) -> String? {
        guard let parts = videoID?.split(separator: ":"), parts.count == 3 else { return nil }
        return "S\(parts[1]), E\(parts[2])"
    }
}

/// Featured titles, full bleed, in the style of the Apple TV app's top shelf: the artwork fills the
/// screen edge to edge and drifts slowly (a gentle Ken Burns move in place of a trailer), titles cross-
/// fade, and the logo, details, and Liquid Glass buttons sit over a soft scrim at the bottom left.
/// On tvOS the hero is focusable and the remote pages through it (left/right at the edge of the
/// buttons); on touch it swipes; on the Mac it swipes with the trackpad. It advances on its own
/// until the viewer interacts.
struct HeroCarousel: View {
    let items: [MetaPreview]
    @State private var index = 0
    @State private var interacted = false
    /// While the viewer is on the hero's buttons it must hold still; rotating under the focus would move
    /// their selection to a different title.
    @FocusState private var focus: HeroInfo.Focus?
    #if os(macOS)
    @State private var hovering = false
    #endif

    var body: some View {
        let item = items[min(index, items.count - 1)]
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                ZStack {
                    HeroBackdrop(url: item.backdropURL, size: proxy.size)
                        .id(item.id)
                        .transition(.opacity)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                HeroScrim()
                HeroInfo(item: item, count: items.count, index: index, focus: $focus)
                    .padding(.horizontal, Theme.Metrics.edge)
                    .padding(.bottom, bottomInset)
            }
            .animation(Theme.Motion.hero, value: index)
            #if os(tvOS)
            .onMoveCommand { direction in
                // Left from the first button or right from the last pages the hero, like the Apple TV app.
                if direction == .left, focus == .watch { interacted = true; step(-1) }
                if direction == .right, focus == .list { interacted = true; step(1) }
            }
            #elseif os(iOS)
            .gesture(DragGesture(minimumDistance: 30).onEnded { value in
                interacted = true
                step(value.translation.width < 0 ? 1 : -1)
            })
            #elseif os(macOS)
            // Mac: two-finger trackpad swipes (and horizontal mouse wheels), click-drag, and arrows that
            // appear on hover.
            .overlay { MacHeroControls(hovering: $hovering) { delta in interacted = true; step(delta) } }
            .gesture(DragGesture(minimumDistance: 30).onEnded { value in
                interacted = true
                step(value.translation.width < 0 ? 1 : -1)
            })
            .onHover { hovering = $0 }
            #endif
        }
        .containerRelativeFrame(.horizontal)
        .containerRelativeFrame(.vertical) { height, _ in max(height * Theme.Metrics.heroHeightRatio, minimumHeight) }
        .task(id: interacted || focus != nil || isHovering) {
            guard !interacted, focus == nil, !isHovering else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(9))
                guard !Task.isCancelled else { return }
                step(1)
            }
        }
    }

    /// Rotation pauses while the pointer rests on the hero (Mac), like it does while the remote is on it.
    private var isHovering: Bool {
        #if os(macOS)
        return hovering
        #else
        return false
        #endif
    }

    private var minimumHeight: CGFloat {
        #if os(tvOS)
        return 760
        #elseif os(macOS)
        return 460
        #else
        return 520
        #endif
    }

    private var bottomInset: CGFloat {
        #if os(tvOS)
        return 70
        #else
        return 36
        #endif
    }

    private func step(_ delta: Int) {
        guard !items.isEmpty else { return }
        index = (index + delta + items.count) % items.count
    }
}

/// The hero artwork with a slow push-in, restarted for every title.
private struct HeroBackdrop: View {
    let url: URL?
    let size: CGSize
    @State private var drift = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Artwork(url: url, maxPixel: 3840)
            .frame(width: size.width, height: size.height)
            .scaleEffect(drift ? 1.08 : 1.0, anchor: .center)
            .offset(x: drift ? -size.width * 0.015 : 0)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 18)) { drift = true }
            }
    }
}

/// Darkens only where type sits: bottom (into the page), left (behind the text), and a little at the
/// top so the tab bar stays legible over bright artwork.
private struct HeroScrim: View {
    var body: some View {
        ZStack {
            LinearGradient(stops: [.init(color: .clear, location: 0.45),
                                   .init(color: Theme.Colors.canvas.opacity(0.75), location: 0.8),
                                   .init(color: Theme.Colors.canvas, location: 1)],
                           startPoint: .top, endPoint: .bottom)
            LinearGradient(stops: [.init(color: .black.opacity(0.6), location: 0), .init(color: .clear, location: 0.55)],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: .black.opacity(0.35), location: 0), .init(color: .clear, location: 0.18)],
                           startPoint: .top, endPoint: .bottom)
        }
        .allowsHitTesting(false)
    }
}

struct HeroInfo: View {
    enum Focus: Hashable { case watch, list }

    let item: MetaPreview
    let count: Int
    let index: Int
    var focus: FocusState<Focus?>.Binding
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            TitleLogo(logo: item.logoURL, title: item.name, maxWidth: logoWidth)
            MetaInfoLine(parts: metaParts, ratings: item.ratingsAndSynopsis.ratings)
            if let description = item.ratingsAndSynopsis.description {
                Text(description)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Colors.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: Theme.Metrics.landscapeWidth * 2.2, alignment: .leading)
            }
            HStack(spacing: 16) {
                NavigationLink(value: Route.title(item)) {
                    Label("Watch Now", systemImage: "play.fill")
                }
                .pillButtonStyle(.primary)
                .focused(focus, equals: .watch)
                Button {
                    app.setInList(item, !(app.libraryItem(item.id)?.isInLibrary ?? false))
                } label: {
                    let _ = app.libraryRevision
                    Image(systemName: app.libraryItem(item.id)?.isInLibrary == true ? "checkmark" : "plus")
                }
                .pillButtonStyle(.icon)
                .focused(focus, equals: .list)
                Spacer()
                PageDots(count: count, index: index)
            }
            .tvFocusSection()
        }
    }

    private var metaParts: [String?] {
        let genres: String? = item.genres.map { $0.prefix(2).joined(separator: ", ") }
        return [item.releaseInfo, genres]
    }

    private var logoWidth: CGFloat {
        #if os(tvOS)
        return 640
        #else
        return 360
        #endif
    }
}

/// Page indicator on a small Liquid Glass capsule, like the Apple TV app's.
struct PageDots: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: dot) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == index ? Color.white : Color.white.opacity(0.4))
                    .frame(width: i == index ? dot * 2.8 : dot, height: dot)
            }
        }
        .padding(.horizontal, dot * 1.6)
        .padding(.vertical, dot * 1.1)
        .liquidGlass(in: Capsule())
        .animation(Theme.Motion.focus, value: index)
    }

    private var dot: CGFloat {
        #if os(tvOS)
        return 10
        #else
        return 7
        #endif
    }
}

/// The title's logo artwork, falling back to the title set large.
struct TitleLogo: View {
    let logo: URL?
    let title: String
    var maxWidth: CGFloat
    @State private var failed = false

    var body: some View {
        if let logo, !failed {
            LogoImage(url: logo, maxWidth: maxWidth) { failed = true }
        } else {
            Text(title)
                .font(Theme.Fonts.heroTitle)
                .foregroundStyle(.white)
                .lineLimit(2)
                .shadow(color: .black.opacity(0.4), radius: 12)
        }
    }
}

private struct LogoImage: View {
    let url: URL
    let maxWidth: CGFloat
    let onFailure: () -> Void
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: maxWidth, maxHeight: maxWidth * 0.36, alignment: .leading)
                    .shadow(color: .black.opacity(0.35), radius: 14)
            } else {
                Color.clear.frame(width: maxWidth, height: maxWidth * 0.2)
            }
        }
        .task(id: url) {
            if let loaded = await ImagePipeline.shared.image(url, maxPixel: Int(maxWidth * 2)) {
                withAnimation(.easeOut(duration: 0.3)) { image = loaded }
            } else if !Task.isCancelled {
                onFailure()
            }
        }
    }
}

/// "2024 · ★ 7.8 · Drama, Thriller"
struct MetaLine: View {
    let parts: [String?]

    var body: some View {
        Text(parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ·  "))
            .font(Theme.Fonts.meta)
            .foregroundStyle(Theme.Colors.secondary)
    }
}

#if os(macOS)
import AppKit

/// Arrows on hover plus a scroll-wheel monitor for trackpad swipes, active only while the pointer is over
/// the hero so it never steals scrolling from the rest of Home.
private struct MacHeroControls: View {
    @Binding var hovering: Bool
    let step: (Int) -> Void
    @State private var monitor: Any?
    @State private var accumulated: CGFloat = 0
    @State private var fired = false
    @State private var lastWheelStep = Date.distantPast

    var body: some View {
        HStack {
            arrow("chevron.left") { step(-1) }
            Spacer()
            arrow("chevron.right") { step(1) }
        }
        .padding(.horizontal, 18)
        .opacity(hovering ? 1 : 0)
        .animation(Theme.Motion.focus, value: hovering)
        .onChange(of: hovering) { _, isHovering in isHovering ? install() : remove() }
        .onDisappear { remove() }
    }

    private func arrow(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .bold))
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // Only clearly horizontal gestures page the hero; vertical scrolling passes through to Home.
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return event }
            // Trackpad inertia after the fingers lift is ignored, so one swipe is exactly one step.
            guard event.momentumPhase == [] else { return nil }
            if event.phase == [] {
                // A horizontal mouse wheel has no gesture phases: one notch is one step, debounced.
                if Date().timeIntervalSince(lastWheelStep) > 0.35 {
                    lastWheelStep = Date()
                    step(event.scrollingDeltaX > 0 ? -1 : 1)
                }
                return nil
            }
            if event.phase == .began { accumulated = 0; fired = false }
            accumulated += event.scrollingDeltaX
            if !fired, abs(accumulated) > 50 {
                fired = true
                step(accumulated > 0 ? -1 : 1)   // natural scrolling: fingers moving left shows the next title
            }
            if event.phase == .ended || event.phase == .cancelled { accumulated = 0; fired = false }
            return nil
        }
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
#endif
