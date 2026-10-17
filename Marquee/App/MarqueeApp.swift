import SwiftUI
import MarqueeKit

@main
struct MarqueeApp: App {
    @StateObject private var app = AppModel()
    @StateObject private var playback = PlaybackCenter()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(playback)
                .onChange(of: scenePhase) { _, phase in
                    // Leaving the foreground is the last reliable moment to save progress to the account.
                    if phase == .background { app.pushNow() }
                    if phase == .active { Task { await app.refresh() } }
                }
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 800)
        .windowStyle(.hiddenTitleBar)
        #endif
    }
}
