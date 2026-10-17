import SwiftUI
import MarqueeKit

/// Runs one playback: resolve sources, walk the bounded `PlaybackPlan`, report progress, and offer the
/// next episode. All failure handling lives here, in one linear state machine.
@MainActor
final class PlayerSession: ObservableObject {
    enum Phase: Equatable {
        case finding
        case starting(attempt: Int, of: Int)
        case playing
        case failed(String)
    }

    enum EngineKind { case native, mpv }

    @Published private(set) var phase: Phase = .finding
    @Published private(set) var engineKind: EngineKind?
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isBuffering = false
    @Published private(set) var video: Video?
    @Published private(set) var nextEpisode: Video?
    @Published var upNextCountdown: Int?

    let meta: MetaPreview
    private let explicit: RankedStream?
    private var resumeAt: TimeInterval
    private weak var app: AppModel?

    private(set) var native: NativeEngine?
    private(set) var mpv: MPVEngine?
    private var plan: [PlaybackPlan.Attempt] = []
    private var attemptIndex = 0
    private var watchdog: Task<Void, Never>?
    private var lastRecorded: TimeInterval = 0
    private var episodes: [Video] = []
    private var countdownTask: Task<Void, Never>?

    init(request: PlaybackRequest) {
        meta = request.meta
        video = request.video
        explicit = request.explicit
        resumeAt = request.resumeAt
    }

    var title: String {
        if let video, let label = video.episodeLabel { return "\(meta.name) · \(label)" }
        return meta.name
    }

    var episodeTitle: String? { video.flatMap { $0.title == meta.name ? nil : $0.title } }

    var engine: PlayerEngine? {
        switch engineKind {
        case .native: native
        case .mpv: mpv
        case nil: nil
        }
    }

    // MARK: Lifecycle

    func start(app: AppModel) {
        self.app = app
        Task { await resolveAndPlay() }
        if meta.type == "series" { Task { await loadEpisodes() } }
    }

    func close() {
        recordProgress(force: true)
        watchdog?.cancel()
        countdownTask?.cancel()
        native?.stop()
        mpv?.stop()
        native = nil
        mpv = nil
        app?.pushNow()
    }

    func retry() {
        Task { await resolveAndPlay() }
    }

    private func resolveAndPlay() async {
        guard let app else { return }
        phase = .finding
        let candidates: [RankedStream]
        if let explicit {
            candidates = [explicit]
        } else {
            candidates = await app.session.rankedStreams(type: meta.type, id: video?.id ?? meta.id)
        }
        plan = PlaybackPlan(candidates: candidates, explicit: explicit != nil,
                            streamingServer: app.settings.streamingServer, title: title).attempts
        attemptIndex = 0
        guard !plan.isEmpty else {
            phase = .failed(candidates.isEmpty
                            ? "No sources were found. Check your add-ons in Settings."
                            : "These sources need a streaming server for torrents. Add one in Settings.")
            return
        }
        runAttempt()
    }

    private func runAttempt() {
        guard attemptIndex < plan.count else {
            phase = .failed(explicit != nil
                            ? "This source didn't play. Choose another one from Sources."
                            : "Couldn't start playback from the best sources. Try picking one from Sources.")
            return
        }
        let attempt = plan[attemptIndex]
        let sourceNumber = Set(plan.prefix(attemptIndex + 1).map(\.candidate)).count
        let totalSources = Set(plan.map(\.candidate)).count
        phase = .starting(attempt: sourceNumber, of: totalSources)
        let engine = engine(for: attempt.engine)
        engine.onEvent = { [weak self] event in self?.handle(event, attempt: attempt) }
        engine.load(attempt.source, startAt: resumeAt)
        watchdog?.cancel()
        let index = attemptIndex
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: attempt.startTimeout)
            guard !Task.isCancelled, let self, self.attemptIndex == index, self.phase != .playing else { return }
            self.advance()
        }
    }

    private func engine(for kind: PlaybackSource.Engine) -> PlayerEngine {
        switch kind {
        case .native:
            mpv?.stop(); mpv = nil
            let engine = native ?? NativeEngine()
            native = engine
            engineKind = .native
            return engine
        case .mpv:
            native?.stop()
            let engine = mpv ?? MPVEngine()
            mpv = engine
            engineKind = .mpv
            return engine
        }
    }

    private func advance() {
        watchdog?.cancel()
        // Resume from wherever the failed attempt got to, so a mid-play failover does not restart the episode.
        if position > 5 { resumeAt = position }
        attemptIndex += 1
        runAttempt()
    }

    private func handle(_ event: PlayerEvent, attempt: PlaybackPlan.Attempt) {
        guard attemptIndex < plan.count, plan[attemptIndex] == attempt else { return }   // a stale engine's event
        switch event {
        case .started:
            watchdog?.cancel()
            withAnimation(Theme.Motion.content) { phase = .playing }
        case let .progress(position, duration):
            self.position = position
            if duration > 0 { self.duration = duration }
            recordProgress(force: false)
            if nextEpisode != nil, duration > 0, duration - position < 25, upNextCountdown == nil, phase == .playing {
                startUpNextCountdown()
            }
        case let .buffering(buffering):
            isBuffering = buffering
        case .ended:
            recordProgress(force: true, finished: true)
            if nextEpisode != nil { playNext() }
        case .failed:
            advance()
        }
    }

    // MARK: Progress

    private func recordProgress(force: Bool, finished: Bool = false) {
        guard let app, duration > 0, phase == .playing || finished else { return }
        guard force || abs(position - lastRecorded) >= 10 else { return }
        lastRecorded = position
        app.recordProgress(meta, videoID: video?.id, position: finished ? duration : position, duration: duration)
    }

    // MARK: Up Next

    private func loadEpisodes() async {
        guard let app, let detail = try? await app.session.addonService.meta(type: meta.type, id: meta.id, in: app.settings.addons) else { return }
        episodes = detail.videos
            .filter { ($0.season ?? 0) > 0 }
            .sorted { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) }
        if let current = video, let full = detail.videos.first(where: { $0.id == current.id }) { video = full }
        updateNextEpisode()
    }

    private func updateNextEpisode() {
        guard let current = video, let index = episodes.firstIndex(where: { $0.id == current.id }),
              index + 1 < episodes.count else { nextEpisode = nil; return }
        let next = episodes[index + 1]
        nextEpisode = (next.released ?? .distantPast) <= Date() ? next : nil
    }

    private func startUpNextCountdown() {
        upNextCountdown = 10
        countdownTask = Task { [weak self] in
            while let self, let remaining = self.upNextCountdown, remaining > 0, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, self.upNextCountdown != nil else { return }
                self.upNextCountdown = remaining - 1
            }
            guard !Task.isCancelled, let self, self.upNextCountdown == 0 else { return }
            self.playNext()
        }
    }

    func cancelUpNext() {
        countdownTask?.cancel()
        upNextCountdown = nil
        nextEpisode = nil   // the viewer said no; do not ask again for this episode
    }

    func playNext() {
        guard let next = nextEpisode else { return }
        recordProgress(force: true, finished: true)
        countdownTask?.cancel()
        upNextCountdown = nil
        video = next
        resumeAt = 0
        position = 0
        duration = 0
        lastRecorded = 0
        updateNextEpisode()
        Task { await resolveAndPlay() }
    }
}
