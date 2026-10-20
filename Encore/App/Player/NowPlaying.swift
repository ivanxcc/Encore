import MediaPlayer
import SwiftUI
import EncoreKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Tells the system what is playing when libmpv is the engine (the system player does this for itself):
/// the Lock Screen and Control Center on iPhone and iPad, the TV's Now Playing and the remote's
/// controls on Apple TV, the menu bar's Now Playing on the Mac. It also takes their commands
/// (play/pause, skip, scrub, next episode) and handles audio interruptions such as a phone call.
@MainActor
final class NowPlayingController {
    static let shared = NowPlayingController()

    private weak var session: PlayerSession?
    private weak var engine: MPVEngine?
    private var info: [String: Any] = [:]
    private var artworkURL: URL?
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var interruptionToken: NSObjectProtocol?
    private var wasPlayingBeforeInterruption = false

    func begin(session: PlayerSession, engine: MPVEngine) {
        guard self.session !== session || self.engine !== engine else { return }
        end()
        self.session = session
        self.engine = engine
        #if os(iOS) || os(tvOS)
        // iOS picks the "now playing" app from whoever owns an active playback session and listens for
        // remote control; say both explicitly rather than relying on libmpv's audio unit to imply them.
        try? AVAudioSession.sharedInstance().setActive(true)
        UIApplication.shared.beginReceivingRemoteControlEvents()
        #endif
        installCommands()
        observeInterruptions()
        info = [
            MPMediaItemPropertyTitle: session.episodeTitle ?? session.meta.name,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if session.episodeTitle != nil {
            info[MPMediaItemPropertyArtist] = session.meta.name
            info[MPMediaItemPropertyAlbumTitle] = session.video?.episodeLabel
        }
        publish()
        loadArtwork(session.meta.backdropURL ?? session.meta.posterURL)
    }

    /// Call on every progress tick and whenever play/pause changes.
    func update(position: TimeInterval, duration: TimeInterval, paused: Bool) {
        guard session != nil else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        info[MPNowPlayingInfoPropertyPlaybackRate] = paused ? 0.0 : 1.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        publish(paused: paused)
    }

    /// The episode changed (Next Episode): new title and artwork, same session.
    func refreshMetadata() {
        guard let session, let engine else { return }
        self.session = nil
        begin(session: session, engine: engine)
    }

    func end() {
        for (command, target) in commandTargets { command.removeTarget(target) }
        commandTargets = []
        if let interruptionToken { NotificationCenter.default.removeObserver(interruptionToken) }
        interruptionToken = nil
        session = nil
        engine = nil
        info = [:]
        artworkURL = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if os(iOS) || os(tvOS)
        UIApplication.shared.endReceivingRemoteControlEvents()
        #endif
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        #endif
    }

    private func publish(paused: Bool? = nil) {
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        #if os(macOS)
        if let paused { center.playbackState = paused ? .paused : .playing }
        #endif
    }

    // MARK: Commands

    private func installCommands() {
        let center = MPRemoteCommandCenter.shared()
        // Start clean: a target left from an earlier player would swallow the remote's presses.
        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
                        center.skipForwardCommand, center.skipBackwardCommand,
                        center.changePlaybackPositionCommand, center.nextTrackCommand] {
            command.removeTarget(nil)
        }
        // Off unless used: enabled commands with no target draw dead buttons on the Now Playing card.
        center.previousTrackCommand.isEnabled = false
        center.seekForwardCommand.isEnabled = false
        center.seekBackwardCommand.isEnabled = false
        func on(_ command: MPRemoteCommand, _ handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            command.isEnabled = true
            commandTargets.append((command, command.addTarget(handler: handler)))
        }
        on(center.playCommand) { [weak self] _ in self?.engine?.play(); self?.syncState(); return .success }
        on(center.pauseCommand) { [weak self] _ in self?.engine?.pause(); self?.syncState(); return .success }
        on(center.togglePlayPauseCommand) { [weak self] _ in
            guard let engine = self?.engine else { return .noActionableNowPlayingItem }
            engine.isPaused ? engine.play() : engine.pause()
            self?.syncState()
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        on(center.skipForwardCommand) { [weak self] _ in self?.skip(10); return .success }
        on(center.skipBackwardCommand) { [weak self] _ in self?.skip(-10); return .success }
        on(center.changePlaybackPositionCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.engine?.seek(to: event.positionTime)
            return .success
        }
        if session?.canPlayNext == true {
            on(center.nextTrackCommand) { [weak self] _ in self?.session?.playNext(); return .success }
        } else {
            center.nextTrackCommand.isEnabled = false
        }
    }

    private func skip(_ seconds: TimeInterval) {
        guard let session, let engine else { return }
        engine.seek(to: max(0, session.position + seconds))
    }

    private func syncState() {
        guard let session, let engine else { return }
        update(position: session.position, duration: session.duration, paused: engine.isPaused)
    }

    // MARK: Interruptions (a call, Siri, another app's audio)

    private func observeInterruptions() {
        #if os(iOS) || os(tvOS)
        interruptionToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init)
            MainActor.assumeIsolated {
                guard let self, let engine = self.engine else { return }
                switch type {
                case .began:
                    self.wasPlayingBeforeInterruption = !engine.isPaused
                    engine.pause()
                    self.syncState()
                case .ended:
                    if self.wasPlayingBeforeInterruption, options?.contains(.shouldResume) == true {
                        try? AVAudioSession.sharedInstance().setActive(true)
                        engine.play()
                        self.syncState()
                    }
                default:
                    break
                }
            }
        }
        #endif
    }

    // MARK: Artwork

    /// Built outside the main actor: the system calls the image handler from its own queue.
    nonisolated private static func artwork(_ image: CGImage) -> MPMediaItemArtwork {
        #if os(macOS)
        let platformImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        #else
        let platformImage = UIImage(cgImage: image)
        #endif
        return MPMediaItemArtwork(boundsSize: platformImage.size) { _ in platformImage }
    }

    private func loadArtwork(_ url: URL?) {
        guard let url else { return }
        artworkURL = url
        Task { [weak self] in
            guard let image = await ImagePipeline.shared.image(url, maxPixel: 1200) else { return }
            guard let self, self.artworkURL == url else { return }
            self.info[MPMediaItemPropertyArtwork] = Self.artwork(image)
            self.publish()
        }
    }
}
