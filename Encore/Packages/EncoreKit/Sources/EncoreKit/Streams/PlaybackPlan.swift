import Foundation

/// The bounded order in which playback is attempted. Each attempt is one source on one engine.
///
/// Rules (the whole reliability story in one place):
///  - At most `maxSources` sources are tried for an automatic Play, and only the picked one for an
///    explicit pick, so a dead title ends on a clear message in about a minute instead of looping.
///  - A source whose container AVFoundation can open gets the native engine first, then libmpv on the
///    same URL (the cheapest recovery: same bytes, more capable demuxer). Everything else goes straight
///    to libmpv and is never retried natively.
///  - Each attempt gets a start budget; libmpv gets more because large MKVs over debrid open slower.
public struct PlaybackPlan: Sendable {
    public struct Attempt: Hashable, Sendable {
        public let candidate: Int
        public let source: PlaybackSource
        public let engine: PlaybackSource.Engine
        public var startTimeout: Duration { engine == .native ? .seconds(20) : .seconds(30) }
    }

    public static let maxSources = 3

    public let attempts: [Attempt]

    public init(candidates: [RankedStream], explicit: Bool, streamingServer: URL?, title: String) {
        var attempts: [Attempt] = []
        var sourcesUsed = 0
        let limit = explicit ? 1 : Self.maxSources
        for (index, candidate) in candidates.enumerated() where sourcesUsed < limit {
            guard let source = PlaybackSource.resolve(candidate.stream, streamingServer: streamingServer, title: title) else { continue }
            sourcesUsed += 1
            if source.preferredEngine == .native {
                attempts.append(Attempt(candidate: index, source: source, engine: .native))
            }
            attempts.append(Attempt(candidate: index, source: source, engine: .mpv))
        }
        self.attempts = attempts
    }
}
