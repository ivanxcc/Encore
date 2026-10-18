import Foundation
import EncoreKit

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

/// The single contextual button the player offers, like the TV app's "Skip Intro".
enum PlayerAction: Equatable {
    case skip(SkipSegment)
    /// `countdown` is set while Up Next is about to start on its own.
    case nextEpisode(countdown: Int?)

    var title: String {
        switch self {
        case let .skip(segment): segment.kind.actionTitle
        case let .nextEpisode(countdown): countdown.map { "Next Episode in \($0)" } ?? "Next Episode"
        }
    }

    var systemImage: String {
        switch self {
        case .skip: "forward.fill"
        case .nextEpisode: "forward.end.fill"
        }
    }
}
