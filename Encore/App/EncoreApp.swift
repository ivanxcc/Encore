import SwiftUI
import EncoreKit

@main
struct EncoreApp: App {
    @StateObject private var app = AppModel()
    @StateObject private var playback = PlaybackCenter()
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @StateObject private var updater = MacUpdater.shared
    #endif

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
                #if os(macOS)
                // Every launch: offer a newer build if one has been released.
                .task { await updater.check() }
                .sheet(isPresented: $updater.isPromptPresented) { UpdatePromptView(updater: updater) }
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 800)
        .windowStyle(.hiddenTitleBar)
        #endif
    }
}
