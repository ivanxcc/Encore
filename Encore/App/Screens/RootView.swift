import SwiftUI
import EncoreKit

/// Where a shelf or search result leads.
enum Route: Hashable {
    case title(MetaPreview)
    case episode(MetaDetail, Video)
}

/// The app's frame: the Apple TV sidebar on tvOS, iPad, and Mac (it collapses into a tab bar on
/// iPhone), with the "Who's watching?" picker over everything until a profile is chosen.
struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var playback: PlaybackCenter
    @State private var tab: AppTab = .home
    #if os(macOS)
    @State private var sidebar: NavigationSplitViewVisibility = .all
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
        .encoreCanvas()
        .playerPresentation(playback)
        #if os(macOS)
        // While a video plays the window is all picture: no tab bar / toolbar, no traffic lights, in a window
        // or in full screen.
        .toolbar(playback.request == nil ? .automatic : .hidden, for: .windowToolbar)
        .background(WindowChromeController(hidden: playback.request != nil))
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
    /// Mac: a sidebar the app controls, so its toggle stays put on the left (the system toggle jumped to
    /// the window's right edge when the sidebar closed) and the sidebar slides over the artwork.
    private var macTabs: some View {
        NavigationSplitView(columnVisibility: $sidebar) {
            List(selection: Binding(get: { tab }, set: { if let new = $0 { tab = new } })) {
                Label("Home", systemImage: "house").tag(AppTab.home)
                Label("Search", systemImage: "magnifyingglass").tag(AppTab.search)
                Label("Library", systemImage: "rectangle.stack").tag(AppTab.library)
                Label("Settings", systemImage: "gearshape").tag(AppTab.settings)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 260)
            .padding(.top, 34)   // clear of the window buttons and the toggle
            .toolbar(removing: .sidebarToggle)
        } detail: {
            // Every section keeps its own navigation while another is showing, like tabs.
            ZStack {
                section(.home) { HomeView() }
                section(.search) { SearchView() }
                section(.library) { LibraryView() }
                section(.settings) { SettingsView() }
            }
        }
        .toolbar(removing: .sidebarToggle)
        .overlay(alignment: .topLeading) {
            Button {
                withAnimation(.smooth(duration: 0.35)) { sidebar = sidebar == .detailOnly ? .all : .detailOnly }
            } label: {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 32, height: 28)
                    .liquidGlass(in: Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("s", modifiers: [.command, .control])
            .help(sidebar == .detailOnly ? "Show Sidebar" : "Hide Sidebar")
            .padding(.leading, 78)   // just after the window's close / minimize / zoom buttons
            .padding(.top, 9)
            .opacity(playback.request == nil ? 1 : 0)
        }
        .id(app.household.id)
    }

    private func section<Content: View>(_ which: AppTab, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack { content().withRoutes() }
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
            case .title(let meta): DetailView(preview: meta)
            case let .episode(meta, video): EpisodeDetailView(meta: meta, video: video)
            }
        }
    }
}

#if os(macOS)
import AppKit

/// Hides the window's title-bar buttons while playing and restores them afterwards.
private struct WindowChromeController: NSViewRepresentable {
    let hidden: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(kind)?.isHidden = hidden
            }
            window.titlebarAppearsTransparent = true
        }
    }
}
#endif
