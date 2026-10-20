import AVFoundation
import AVKit
import MediaPlayer
import SwiftUI
import EncoreKit
#if canImport(UIKit)
import UIKit
#endif

/// AVFoundation engine for what Apple's stack opens natively (MP4/MOV/HLS). Its reward is the real
/// system player: the Apple TV info panel and transport bar, Picture in Picture, AirPlay, and HDR /
/// Dolby Vision handled by the OS.
@MainActor
final class NativeEngine: PlayerEngine {
    let player = AVPlayer()
    var onEvent: ((PlayerEvent) -> Void)?

    private var statusObservation: NSKeyValueObservation?
    private var controlObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var notificationTokens: [NSObjectProtocol] = []
    private var started = false
    /// Shown by the system's Now Playing for this item.
    var artworkURL: URL?
    /// The show's name under an episode title.
    var subtitle: String?

    #if os(iOS)
    /// Publishes this player to the Lock Screen and Control Center, and routes their commands to it. On
    /// Apple TV the system player view does this itself, and a second publisher would compete with it.
    private lazy var nowPlayingSession: MPNowPlayingSession = {
        let session = MPNowPlayingSession(players: [player])
        session.automaticallyPublishesNowPlayingInfo = true
        return session
    }()
    #endif

    var isPaused: Bool { player.timeControlStatus == .paused }
    var audioTracks: [MediaTrack] { [] }      // the system player UI owns track selection
    var subtitleTracks: [MediaTrack] { [] }
    func selectAudio(_ id: Int) {}
    func selectSubtitle(_ id: Int?) {}

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        // Multichannel route first, so Dolby Digital Plus / Atmos is passed through rather than downmixed.
        AudioSessionConfigurator.configureForPlayback()
    }

    func load(_ source: PlaybackSource, startAt: TimeInterval) {
        teardownObservers()
        started = false
        let options: [String: Any]? = source.headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": source.headers]
        let item = AVPlayerItem(asset: AVURLAsset(url: source.url, options: options))
        #if os(iOS) || os(tvOS)
        let title = AVMutableMetadataItem()
        title.identifier = .commonIdentifierTitle
        title.value = source.title as NSString
        title.extendedLanguageTag = "und"
        var metadata = [title]
        if let subtitle {
            let line = AVMutableMetadataItem()
            line.identifier = .iTunesMetadataTrackSubTitle
            line.value = subtitle as NSString
            line.extendedLanguageTag = "und"
            metadata.append(line)
        }
        item.externalMetadata = metadata
        // Artwork for the Lock Screen, Control Center, and the Apple TV info panel.
        if let artworkURL {
            Task { [weak item] in
                guard let image = await ImagePipeline.shared.image(artworkURL, maxPixel: 1200),
                      let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.85), let item else { return }
                let artwork = AVMutableMetadataItem()
                artwork.identifier = .commonIdentifierArtwork
                artwork.value = data as NSData
                artwork.dataType = kCMMetadataBaseDataType_JPEG as String
                artwork.extendedLanguageTag = "und"
                item.externalMetadata.append(artwork)
            }
        }
        #endif

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let message = item.error?.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    if startAt > 1 { self.player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600)) }
                case .failed:
                    self.onEvent?(.failed(message ?? "This source can't be played."))
                default:
                    break
                }
            }
        }
        controlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in
                guard let self else { return }
                switch status {
                case .playing:
                    if !self.started { self.started = true; self.onEvent?(.started) }
                    self.onEvent?(.buffering(false))
                case .waitingToPlayAtSpecifiedRate:
                    self.onEvent?(.buffering(true))
                default:
                    break
                }
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 2), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, let item = self.player.currentItem else { return }
                let duration = item.duration.seconds
                self.onEvent?(.progress(position: time.seconds, duration: duration.isFinite ? duration : 0))
            }
        }
        let center = NotificationCenter.default
        notificationTokens = [
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onEvent?(.ended) }
            },
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] note in
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                MainActor.assumeIsolated { self?.onEvent?(.failed(error?.localizedDescription ?? "Playback stopped.")) }
            },
        ]
        player.replaceCurrentItem(with: item)
        player.play()
        #if os(iOS)
        nowPlayingSession.becomeActiveIfPossible { _ in }
        #endif
    }

    func play() { player.play() }
    func pause() { player.pause() }
    func seek(to seconds: TimeInterval) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        teardownObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private func teardownObservers() {
        statusObservation = nil
        controlObservation = nil
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens = []
    }
}

/// The system player view around `NativeEngine.player`.
#if os(macOS)
struct NativePlayerView: NSViewRepresentable {
    let player: AVPlayer
    var action: PlayerAction? = nil
    /// Unused on the Mac: its countdown button is drawn over the player, with its own cancel.
    var dismiss: (() -> Void)? = nil
    var perform: () -> Void = {}

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
#else
struct NativePlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    var action: PlayerAction? = nil
    /// Cancels a Next Episode countdown ("Watch Credits").
    var dismiss: (() -> Void)? = nil
    var perform: () -> Void = {}

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        #if os(tvOS)
        // Match Content: the system player switches the TV to the item's frame rate and dynamic range
        // (including true Dolby Vision) when the viewer has Match Content on in tvOS Settings.
        controller.appliesPreferredDisplayCriteriaAutomatically = DisplayModeMatcher.isEnabledInApp
        #endif
        #if os(iOS)
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.updatesNowPlayingInfoCenter = false   // NativeEngine's MPNowPlayingSession publishes
        #endif
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
        #if os(tvOS)
        let perform = self.perform
        var actions: [UIAction] = []
        if let action {
            actions.append(UIAction(title: action.title, image: UIImage(systemName: action.systemImage)) { _ in perform() })
            // A countdown must always be cancellable from the remote, not only by waiting it out.
            if action.isCountdown, let dismiss {
                actions.insert(UIAction(title: "Watch Credits", image: UIImage(systemName: "xmark")) { _ in dismiss() }, at: 0)
            }
        }
        controller.contextualActions = actions
        #endif
    }
}
#endif
