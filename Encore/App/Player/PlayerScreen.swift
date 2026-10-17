import SwiftUI
import EncoreKit

/// The full-screen player. The native engine brings the system player UI; libmpv gets controls drawn to
/// match it, so both feel like the same player.
struct PlayerScreen: View {
    let request: PlaybackRequest
    let onClose: () -> Void
    @EnvironmentObject private var app: AppModel
    @StateObject private var session: PlayerSession

    init(request: PlaybackRequest, onClose: @escaping () -> Void) {
        self.request = request
        self.onClose = onClose
        _session = StateObject(wrappedValue: PlayerSession(request: request))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch session.engineKind {
            case .native:
                if let native = session.native {
                    NativePlayerView(player: native.player).ignoresSafeArea()
                }
            case .mpv:
                if let mpv = session.mpv {
                    MPVVideoView(engine: mpv).ignoresSafeArea()
                    if session.phase == .playing {
                        MPVControls(session: session, engine: mpv, close: close)
                    }
                }
            case nil:
                EmptyView()
            }

            if session.phase != .playing {
                LoadingCurtain(session: session, close: close)
                    .transition(.opacity)
            }

            if let countdown = session.upNextCountdown, let next = session.nextEpisode {
                UpNextCard(meta: session.meta, next: next, countdown: countdown,
                           play: { session.playNext() }, dismiss: { session.cancelUpNext() })
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(Theme.Metrics.edge)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            #if !os(tvOS)
            if session.engineKind == .native, session.phase == .playing {
                CloseButton(action: close)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(20)
            }
            #endif
        }
        .animation(Theme.Motion.content, value: session.phase)
        .animation(Theme.Motion.content, value: session.upNextCountdown != nil)
        .preferredColorScheme(.dark)
        #if os(tvOS) || os(macOS)
        .onExitCommand { close() }
        #endif
        .onAppear { session.start(app: app) }
        .onDisappear { session.close() }
        #if os(iOS)
        .persistentSystemOverlays(.hidden)
        .statusBarHidden()
        #endif
    }

    private func close() {
        session.close()
        onClose()
    }
}

/// Backdrop, title, and what is happening, while sources are found and started. Never a bare spinner.
private struct LoadingCurtain: View {
    @ObservedObject var session: PlayerSession
    let close: () -> Void

    var body: some View {
        ZStack {
            Artwork(url: session.meta.backdropURL, maxPixel: 1920)
                .ignoresSafeArea()
                .overlay(Color.black.opacity(0.55))
                .blur(radius: 20)
            VStack(spacing: 28) {
                TitleLogo(logo: session.meta.logoURL, title: session.meta.name, maxWidth: logoWidth)
                if let episode = session.video?.episodeLabel {
                    Text([episode, session.episodeTitle].compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.Fonts.meta).foregroundStyle(Theme.Colors.secondary)
                }
                status
            }
            .padding(Theme.Metrics.edge)
        }
    }

    @ViewBuilder private var status: some View {
        switch session.phase {
        case .finding:
            HStack(spacing: 12) { ProgressView(); Text("Finding the best source…") }
                .font(Theme.Fonts.meta).foregroundStyle(Theme.Colors.secondary)
        case let .starting(attempt, total):
            HStack(spacing: 12) {
                ProgressView()
                Text(attempt == 1 ? "Starting…" : "Trying another source (\(attempt) of \(total))…")
            }
            .font(Theme.Fonts.meta).foregroundStyle(Theme.Colors.secondary)
        case let .failed(message):
            VStack(spacing: 22) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Fonts.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                HStack(spacing: 18) {
                    Button("Try Again") { session.retry() }.pillButtonStyle(.primary)
                    Button("Close", action: close).pillButtonStyle(.secondary)
                }
            }
        case .playing:
            EmptyView()
        }
    }

    private var logoWidth: CGFloat {
        #if os(tvOS)
        return 600
        #else
        return 320
        #endif
    }
}

private struct UpNextCard: View {
    let meta: MetaPreview
    let next: Video
    let countdown: Int
    let play: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Up Next").font(Theme.Fonts.meta).foregroundStyle(Theme.Colors.secondary)
            Text([next.episodeLabel, next.title].compactMap { $0 }.joined(separator: " · "))
                .font(Theme.Fonts.cardTitle).foregroundStyle(.white).lineLimit(2)
            HStack(spacing: 14) {
                Button(action: play) { Label("Play in \(countdown)", systemImage: "play.fill") }
                    .pillButtonStyle(.primary)
                Button("Not Now", action: dismiss).pillButtonStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: 520, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .tvFocusSection()
    }
}

struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .bold))
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        #if !os(tvOS)
        .keyboardShortcut(.cancelAction)
        #endif
        .accessibilityLabel("Close")
    }
}
