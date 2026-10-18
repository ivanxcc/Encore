import SwiftUI
import EncoreKit

/// Where a shelf or search result leads.
enum Route: Hashable {
    case title(MetaPreview)
}

/// The app's frame: the Apple TV sidebar on tvOS, iPad, and Mac (it collapses into a tab bar on
/// iPhone), with the "Who's watching?" picker over everything until a profile is chosen.
struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var playback: PlaybackCenter
    @State private var tab: AppTab = .home

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

    private var tabs: some View {
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
