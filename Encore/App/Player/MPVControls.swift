import SwiftUI
import EncoreKit
#if os(macOS)
import AppKit
#endif

/// Transport controls for the libmpv engine, laid out like the system player so switching engines is
/// invisible to the viewer: title top-left, track menus top-right, scrubber with elapsed/remaining at the
/// bottom. Fades away while playing.
struct MPVControls: View {
    @ObservedObject var session: PlayerSession
    @ObservedObject var engine: MPVEngine
    let close: () -> Void

    @State private var visible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubPosition: Double?
    #if os(tvOS)
    private enum Focus: Hashable { case surface, action }
    @FocusState private var focus: Focus?
    #endif

    var body: some View {
        ZStack {
            surface
            if visible || session.isBuffering {
                chrome
                    .transition(.opacity)
            }
            if session.isBuffering {
                ProgressView().tint(.white).scaleEffect(1.6)
            }
            // Skip Intro / Next Episode stays on screen even when the rest of the chrome has faded, exactly
            // like the TV app. On Apple TV it takes focus as it appears, so one click of the remote skips.
            if let action = session.action {
                actionButton(action)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.horizontal, Theme.Metrics.edge)
                    .padding(.bottom, bottomPadding + (visible ? actionLift : 0))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: visible)
        .animation(Theme.Motion.content, value: session.action)
        .onAppear { scheduleHide() }
        #if os(tvOS)
        // Move focus only when a button appears or goes away, not on every countdown tick, so a viewer who
        // moved to "Watch Credits" is not pulled back.
        .onChange(of: session.action != nil) { _, hasAction in focus = hasAction ? .action : .surface }
        #endif
        #if os(macOS)
        .onChange(of: visible) { _, isVisible in if !isVisible { NSCursor.setHiddenUntilMouseMoves(true) } }
        #endif
    }

    @ViewBuilder
    private func actionButton(_ action: PlayerAction) -> some View {
        #if os(tvOS)
        HStack(spacing: 14) {
            if action.isCountdown {
                Button("Watch Credits") { session.cancelUpNext() }.pillButtonStyle(.secondary)
            }
            Button { session.performAction() } label: {
                Label(action.title, systemImage: action.systemImage)
            }
            .pillButtonStyle(.primary)
            .focused($focus, equals: .action)
        }
        .tvFocusSection()
        #else
        PlayerActionButton(action: action, perform: { session.performAction(); reveal() },
                           dismiss: action.isCountdown ? { session.cancelUpNext() } : nil)
        #endif
    }

    private var actionLift: CGFloat {
        #if os(tvOS)
        return 90
        #else
        return 70
        #endif
    }

    // MARK: Input surface

    @ViewBuilder private var surface: some View {
        #if os(tvOS)
        Button { toggleVisibility() } label: {
            Color.clear.contentShape(Rectangle())
        }
        .buttonStyle(InvisibleButtonStyle())
        .focusEffectDisabled()
        .focused($focus, equals: .surface)
        .onAppear { focus = .surface }
        .onMoveCommand { direction in
            switch direction {
            case .left: skip(-10)
            case .right: skip(10)
            default: reveal()
            }
        }
        .onPlayPauseCommand { togglePause() }
        #elseif os(macOS)
        // Mac: moving the mouse brings the controls back (and the cursor, which hides with them); a click
        // shows or hides them; a double-click toggles full screen, as in QuickTime and Infuse.
        Color.clear
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active = phase { reveal() }
            }
            .onTapGesture(count: 2) { toggleFullScreen() }
            .onTapGesture { toggleVisibility() }
        #else
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { togglePause() }
            .onTapGesture { toggleVisibility() }
            // Pinch out to fill the screen, pinch in to see the whole picture, as in the system player.
            .gesture(MagnifyGesture().onEnded { value in
                if value.magnification > 1.1, !engine.fillsScreen { engine.toggleFill() }
                if value.magnification < 0.9, engine.fillsScreen { engine.toggleFill() }
            })
        #endif
    }

    // MARK: Chrome

    private var chrome: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, Theme.Metrics.edge)
                .padding(.top, topPadding)
                .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea())
            Spacer()
            #if !os(tvOS)
            centerButtons
            Spacer()
            #endif
            bottomBar
                .padding(.horizontal, Theme.Metrics.edge)
                .padding(.bottom, bottomPadding)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea())
        }
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 16) {
            #if !os(tvOS)
            CloseButton(action: close)
            #endif
            VStack(alignment: .leading, spacing: 4) {
                Text(session.meta.name).font(PlayerType.title)
                if let episode = session.video?.episodeLabel {
                    Text([episode, session.episodeTitle].compactMap { $0 }.joined(separator: " · "))
                        .font(PlayerType.subtitle).foregroundStyle(Theme.Colors.secondary)
                }
                // Infuse-style truth panel: what is actually being decoded and sent to the TV/receiver.
                if !engine.info.videoLine.isEmpty {
                    Label(engine.info.videoLine, systemImage: "film")
                        .font(PlayerType.info).foregroundStyle(Theme.Colors.tertiary)
                }
                if !engine.info.audioLine.isEmpty {
                    Label(engine.info.audioLine, systemImage: "speaker.wave.3")
                        .font(PlayerType.info).foregroundStyle(Theme.Colors.tertiary)
                }
            }
            Spacer()
            trackMenus
        }
    }

    private var trackMenus: some View {
        HStack(spacing: 14) {
            #if os(iOS)
            // Fill the screen (cropping the edges) or fit the whole picture with black bars.
            Button { engine.toggleFill(); reveal() } label: {
                Image(systemName: engine.fillsScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(engine.fillsScreen ? "Fit to Screen" : "Fill Screen")
            #endif
            if session.canPlayNext {
                Button { session.playNext() } label: {
                    Image(systemName: "forward.end.fill").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Next Episode")
            }
            if !engine.audioTracks.isEmpty {
                Menu {
                    ForEach(engine.audioTracks) { track in
                        Button { engine.selectAudio(track.id); reveal() } label: {
                            TrackLabel(title: track.title, selected: track.isSelected)
                        }
                    }
                } label: {
                    Image(systemName: "waveform").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Audio")
            }
            Menu {
                Button { engine.selectSubtitle(nil); reveal() } label: {
                    TrackLabel(title: "Off", selected: !engine.subtitleTracks.contains(where: \.isSelected))
                }
                ForEach(engine.subtitleTracks) { track in
                    Button { engine.selectSubtitle(track.id); reveal() } label: {
                        Label(track.title, systemImage: track.isSelected ? "checkmark" : "")
                    }
                }
            } label: {
                Image(systemName: "captions.bubble").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Subtitles")
            #if os(macOS)
            Button { toggleFullScreen() } label: {
                Image(systemName: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .frame(width: 44, height: 44)
            }
            .keyboardShortcut("f", modifiers: [])
            .accessibilityLabel("Full Screen")
            #endif
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .font(.system(size: 20, weight: .semibold))
    }

    #if !os(tvOS)
    private var centerButtons: some View {
        HStack(spacing: 56) {
            Button { skip(-10) } label: { Image(systemName: "gobackward.10") }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button { togglePause() } label: {
                Image(systemName: engine.isPaused ? "play.fill" : "pause.fill").font(.system(size: 44))
            }
            .keyboardShortcut(.space, modifiers: [])
            Button { skip(10) } label: { Image(systemName: "goforward.10") }
                .keyboardShortcut(.rightArrow, modifiers: [])
        }
        .font(.system(size: 30, weight: .semibold))
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
    #endif

    private var bottomBar: some View {
        VStack(spacing: 10) {
            #if os(tvOS)
            ProgressBar(value: session.duration > 0 ? session.position / session.duration : 0, height: PlayerType.barHeight)
            #else
            Slider(value: Binding(get: { scrubPosition ?? session.position },
                                  set: { scrubPosition = $0 }),
                   in: 0...max(1, session.duration)) { editing in
                if !editing, let target = scrubPosition {
                    engine.seek(to: target)
                    scrubPosition = nil
                }
                reveal()
            }
            #endif
            HStack {
                Text(Self.format(scrubPosition ?? session.position))
                Spacer()
                Text("-" + Self.format(max(0, session.duration - (scrubPosition ?? session.position))))
            }
            .font(PlayerType.time)
            .foregroundStyle(Theme.Colors.secondary)
        }
    }

    private var topPadding: CGFloat {
        #if os(tvOS)
        return 50
        #else
        return 16
        #endif
    }

    private var bottomPadding: CGFloat {
        #if os(tvOS)
        return 60
        #else
        return 20
        #endif
    }

    // MARK: Actions

    #if os(macOS)
    private var isFullScreen: Bool { NSApp.keyWindow?.styleMask.contains(.fullScreen) ?? false }
    private func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
        reveal()
    }
    #endif

    private func toggleVisibility() {
        visible.toggle()
        if visible { scheduleHide() }
    }

    private func reveal() {
        visible = true
        scheduleHide()
    }

    private func togglePause() {
        if engine.isPaused { engine.play() } else { engine.pause() }
        reveal()
    }

    private func skip(_ seconds: Double) {
        engine.seek(to: max(0, session.position + seconds))
        reveal()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, !engine.isPaused, scrubPosition == nil else { return }
            visible = false
        }
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// A button that draws nothing; used as the full-screen remote input surface on tvOS.
struct InvisibleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

private struct TrackLabel: View {
    let title: String
    let selected: Bool

    var body: some View {
        if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}

/// Type and bar sizes for the player's own controls. Apple TV is read from across the room: its sizes
/// match the system player's (tvOS points are resolution independent, so a 4K TV draws them sharper,
/// not smaller).
enum PlayerType {
    #if os(tvOS)
    static let title = Font.system(size: 42, weight: .bold)
    static let subtitle = Font.system(size: 30, weight: .medium)
    static let info = Font.system(size: 24, weight: .medium)
    static let time = Font.system(size: 30, weight: .semibold).monospacedDigit()
    static let barHeight: CGFloat = 14
    #else
    static let title = Theme.Fonts.cardTitle.weight(.semibold)
    static let subtitle = Theme.Fonts.cardSubtitle
    static let info = Theme.Fonts.cardSubtitle
    static let time = Theme.Fonts.cardSubtitle.monospacedDigit()
    static let barHeight: CGFloat = 5
    #endif
}
