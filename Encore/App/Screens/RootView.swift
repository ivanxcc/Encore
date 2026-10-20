import SwiftUI
import EncoreKit

/// Where a shelf or search result leads.
enum Route: Hashable {
    case title(MetaPreview)
    case episode(MetaDetail, Video)
}

/// The app's frame: the Apple TV sidebar on tvOS and iPad (a tab bar on iPhone), floating glass
/// controls and a slide-over sidebar on the Mac, with the "Who's watching?" picker over everything until a profile is chosen.
struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var playback: PlaybackCenter
    @State private var tab: AppTab = .home
    #if os(macOS)
    @State private var sidebarOpen = false
    @State private var searchQuery = ""
    @State private var searchExpanded = false
    @State private var fullScreen = false
    @FocusState private var searchFocused: Bool
    @StateObject private var homeNav = MacNavigator()
    @StateObject private var searchNav = MacNavigator()
    @StateObject private var libraryNav = MacNavigator()
    @StateObject private var settingsNav = MacNavigator()
    #endif

    enum AppTab: Hashable { case home, search, library, settings }

    var body: some View {
        ZStack {
            if app.activeProfile != nil {
                tabs
                    .transition(.opacity)
            } else {
                ProfilePickerView()
                    .transition(.opacity.combined(with: .scale(scale: 1.04)))
            }
        }
        .animation(Theme.Motion.content, value: app.activeProfile?.id)
        #if !os(tvOS)
        // A TV's QR code, scanned with this phone, lands here: choose the account and approve.
        .sheet(item: $app.pendingPair) { request in
            NavigationStack { ApproveDeviceView(initialCode: request.code) }
                .environmentObject(app)
        }
        #endif
        .encoreCanvas()
        .playerPresentation(playback)
        #if os(macOS)
        // Encore draws its own controls over the artwork and puts nothing in the window's toolbar, so the
        // window keeps its close / minimize / zoom buttons with no grey bar behind them, in full screen
        // too. While a video plays the window is all picture.
        .toolbar(playback.request == nil ? .automatic : .hidden, for: .windowToolbar)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .background(WindowChromeController(hidden: playback.request != nil, fullScreen: $fullScreen))
        #endif
    }

    @ViewBuilder private var tabs: some View {
        #if os(macOS)
        macTabs
        #else
        tabView
        #endif
    }

    #if os(macOS)
    /// Mac: every section fills the window, artwork edge to edge. Floating glass controls sit just after
    /// the window buttons: the sidebar button, a back button when there is somewhere to go back to, and
    /// a search pill that grows into a field when clicked. The sidebar slides in over the page (the page
    /// never shifts), and while it is open only its own button stays, to close it.
    private var macTabs: some View {
        ZStack(alignment: .topLeading) {
            // Every section keeps its own navigation while another is showing, like tabs.
            ZStack {
                section(.home, homeNav) { HomeView() }
                section(.search, searchNav) { SearchView(query: $searchQuery) }
                section(.library, libraryNav) { LibraryView() }
                section(.settings, settingsNav) { SettingsView() }
            }
            // A click anywhere on the page takes the focus out of the search field (the Mac doesn't do
            // that by itself for clicks on things that can't take focus), which folds an empty field.
            .simultaneousGesture(TapGesture().onEnded { if searchFocused { searchFocused = false } })

            if sidebarOpen {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { setSidebar(false) }
                    .transition(.opacity)
                MacSidebar(selection: tab) { select($0) }
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            controls
                .padding(.leading, fullScreen ? 20 : 80)   // just after the close / minimize / zoom buttons
                .padding(.top, 10)
                .opacity(playback.request == nil ? 1 : 0)
        }
        .ignoresSafeArea(edges: .top)
        .animation(.smooth(duration: 0.38), value: sidebarOpen)
        .animation(.smooth(duration: 0.38), value: searchExpanded)
        .animation(.smooth(duration: 0.3), value: navigator(for: tab).canGoBack)
        .onChange(of: searchQuery) { _, query in
            if !query.isEmpty, tab != .search { tab = .search }
        }
        .onChange(of: searchFocused) { _, focused in
            // Clicking away folds the field back into its pill, unless it is holding a search.
            if !focused, searchQuery.isEmpty { searchExpanded = false }
        }
        .id(app.household.id)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            // With the sidebar open the button becomes part of its header, beside the window buttons, as in
            // the Mac's own sidebars; closed, it floats as a glass circle.
            ChromeButton(systemImage: "sidebar.leading", help: sidebarOpen ? "Hide Sidebar" : "Show Sidebar",
                         glass: !sidebarOpen) {
                setSidebar(!sidebarOpen)
            }
            .keyboardShortcut("s", modifiers: [.command, .control])

            if !sidebarOpen {
                if navigator(for: tab).canGoBack {
                    ChromeButton(systemImage: "chevron.left", help: "Back") { navigator(for: tab).goBack() }
                        .keyboardShortcut("[", modifiers: .command)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                searchPill
                    .transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
            }
        }
    }

    /// A magnifying glass that opens into a search field, and folds back when you click away.
    private var searchPill: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 18)
            if searchExpanded {
                TextField("Movies, Shows, and More", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($searchFocused)
                    .onSubmit { tab = .search }
                    .onExitCommand { closeSearch() }
                    .transition(.opacity)
                if !searchQuery.isEmpty {
                    Button { searchQuery = ""; searchFocused = true } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, searchExpanded ? 12 : 0)
        .frame(width: searchExpanded ? 300 : 34, height: 34)
        .liquidGlass(in: Capsule())
        .contentShape(Capsule())
        .onTapGesture { openSearch() }
        .help("Search")
        .background {
            Button("Search") { openSearch() }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func openSearch() {
        guard !searchExpanded else { searchFocused = true; return }
        searchExpanded = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { searchFocused = true }
    }

    private func closeSearch() {
        searchQuery = ""
        searchFocused = false
        searchExpanded = false
    }

    private func setSidebar(_ open: Bool) {
        if open { searchFocused = false }
        sidebarOpen = open
    }

    private func select(_ which: AppTab) {
        tab = which
        setSidebar(false)
        if which == .search {
            openSearch()
        } else if searchQuery.isEmpty == false {
            closeSearch()
        }
    }

    private func navigator(for which: AppTab) -> MacNavigator {
        switch which {
        case .home: homeNav
        case .search: searchNav
        case .library: libraryNav
        case .settings: settingsNav
        }
    }

    private func section<Content: View>(_ which: AppTab, _ navigator: MacNavigator,
                                        @ViewBuilder content: () -> Content) -> some View {
        NavigationStack { content().withRoutes() }
            .environment(\.macNavigator, navigator)
            .environment(\.macChromeInset, 54)
            .opacity(tab == which ? 1 : 0)
            .allowsHitTesting(tab == which)
            .accessibilityHidden(tab != which)
    }
    #endif

    private var tabView: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                NavigationStack { HomeView().withRoutes() }
            }
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search) {
                NavigationStack { SearchView().withRoutes() }
            }
            Tab("Library", systemImage: "rectangle.stack", value: AppTab.library) {
                NavigationStack { LibraryView().withRoutes() }
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                NavigationStack { SettingsView().withRoutes() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .id(app.household.id)   // a household switch rebuilds every screen from the new session
    }
}

extension View {
    func withRoutes() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .title(let meta): DetailView(preview: meta).pushedPage()
            case let .episode(meta, video): EpisodeDetailView(meta: meta, video: video).pushedPage()
            }
        }
    }
}

#if os(macOS)
import AppKit

/// Hides the window's title-bar buttons while playing and restores them afterwards, and reports
/// whether the window is in full screen (where there are no window buttons to leave room for).
private struct WindowChromeController: NSViewRepresentable {
    let hidden: Bool
    @Binding var fullScreen: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(kind)?.isHidden = hidden
            }
            window.titlebarAppearsTransparent = true
            context.coordinator.observe(window) { fullScreen = $0 }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private weak var window: NSWindow?
        private var tokens: [NSObjectProtocol] = []

        func observe(_ window: NSWindow, changed: @escaping (Bool) -> Void) {
            guard window !== self.window else { return }
            self.window = window
            tokens.forEach(NotificationCenter.default.removeObserver)
            changed(window.styleMask.contains(.fullScreen))
            tokens = [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                    changed(name == NSWindow.willEnterFullScreenNotification)
                }
            }
        }

        deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }
}

/// A round glass button for the Mac's floating window controls.
private struct ChromeButton: View {
    let systemImage: String
    let help: String
    var glass = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(glass ? .primary : .secondary)
                .frame(width: 34, height: 34)
                .background {
                    if glass {
                        Color.clear.liquidGlass(in: Circle())
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.white.opacity(hovering ? 0.12 : 0))
                            .frame(width: 30, height: 26)
                    }
                }
                .scaleEffect(glass && hovering ? 1.06 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.2), value: hovering)
    }
}

/// The Mac sidebar: a floating glass panel over the page, with the sections and who's watching.
private struct MacSidebar: View {
    let selection: RootView.AppTab
    let select: (RootView.AppTab) -> Void
    @EnvironmentObject private var app: AppModel

    private let items: [(RootView.AppTab, String, String)] = [
        (.home, "Home", "house"),
        (.search, "Search", "magnifyingglass"),
        (.library, "Library", "rectangle.stack"),
        (.settings, "Settings", "gearshape"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items, id: \.0) { item in
                SidebarRow(title: item.1, systemImage: item.2, selected: selection == item.0) { select(item.0) }
            }
            Spacer()
            if let profile = app.activeProfile {
                Button { app.activeProfile = nil } label: {
                    HStack(spacing: 10) {
                        ProfileAvatar(profile: profile, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(profile.name).font(.system(size: 13, weight: .semibold))
                            Text("Switch Profile").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(8)
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 58)   // below the window buttons and the sidebar button
        .padding(.bottom, 12)
        .frame(width: 240)
        .frame(maxHeight: .infinity)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 30, x: 8)
        .padding(8)
    }
}

private struct SidebarRow: View {
    let title: String
    let systemImage: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 14, weight: selected ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white.opacity(selected ? 0.16 : hovering ? 0.08 : 0))
                }
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
#endif
