import Foundation
import MarqueeKit

/// What both playback engines (AVFoundation and libmpv) report back.
enum PlayerEvent {
    /// First frame is on screen.
    case started
    case progress(position: TimeInterval, duration: TimeInterval)
    case buffering(Bool)
    case ended
    case failed(String)
}

struct MediaTrack: Identifiable, Hashable {
    let id: Int
    let title: String
    let isSelected: Bool
}

/// The common surface of the two engines. Kept deliberately small: everything the shared state machine
/// and controls need, nothing engine-specific.
@MainActor
protocol PlayerEngine: AnyObject {
    var onEvent: ((PlayerEvent) -> Void)? { get set }
    var isPaused: Bool { get }
    func load(_ source: PlaybackSource, startAt: TimeInterval)
    func play()
    func pause()
    func seek(to seconds: TimeInterval)
    func stop()
    var audioTracks: [MediaTrack] { get }
    var subtitleTracks: [MediaTrack] { get }
    func selectAudio(_ id: Int)
    func selectSubtitle(_ id: Int?)
}
