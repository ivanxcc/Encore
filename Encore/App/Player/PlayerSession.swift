import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
#endif
import EncoreKit

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
    /// Intro / recap / credits markers for the playing episode.
    @Published private(set) var skipSegments: [SkipSegment] = []
    /// The one contextual button the player shows right now ("Skip Intro", "Next Episode"), if any.
    @Published private(set) var action: PlayerAction?

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
    private var upNextPolicy = UpNextPolicy()
    /// "Watch Credits" was chosen: no countdown starts again for this episode (it used to restart on the
    /// next tick, so the credits had to be declined over and over); Next Episode stays one press away.
    private var upNextDeclined = false
    /// The duration the current markers were looked up for.
    private var segmentsDuration: TimeInterval = 0
    private var segmentsTask: Task<Void, Never>?
    private var pauseObservation: AnyCancellable?
    /// Closed by the viewer. Work still in flight (a source lookup, a countdown, the end of the episode)
    /// must not start anything after this: it used to start the next episode in the background, with no
    /// way to stop it but quitting the app.
    private var closed = false
    /// Called when the session ends on its own (the credits were watched to the end, or there is no next
    /// episode), so the player can close back to the page it was opened from.
    var onFinished: (() -> Void)?
    /// Segments the viewer already skipped or watched through, so the button does not come back.
    private var dismissedSegments: Set<SkipSegment> = []

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
        guard !closed else { return }
        recordProgress(force: true)
        closed = true
        segmentsTask?.cancel()
        watchdog?.cancel()
        countdownTask?.cancel()
        native?.stop()
        mpv?.stop()
        native = nil
        mpv = nil
        pauseObservation = nil
        NowPlayingController.shared.end()
        keepScreenAwake(false)
        app?.pushNow()
    }

    func retry() {
        Task { await resolveAndPlay() }
    }

    private func resolveAndPlay() async {
        guard let app, !closed else { return }
        phase = .finding
        let candidates: [RankedStream]
        if let explicit {
            candidates = [explicit]
        } else {
            candidates = await app.session.rankedStreams(type: meta.type, id: video?.id ?? meta.id,
                                                         limits: NetworkMonitor.shared.limits)
        }
        guard !closed else { return }
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
        guard !closed else { return }
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
            NowPlayingController.shared.end()   // the system player publishes its own
            let engine = native ?? NativeEngine()
            engine.artworkURL = meta.backdropURL ?? meta.posterURL
            engine.subtitle = episodeTitle != nil ? meta.name : nil
            native = engine
            engineKind = .native
            return engine
        case .mpv:
            native?.stop()
            let engine = mpv ?? MPVEngine()
            mpv = engine
            engineKind = .mpv
            // Keep the system's Now Playing in step when the viewer pauses from our own controls.
            pauseObservation = engine.$isPaused.dropFirst().sink { [weak self] paused in
                guard let self, self.engineKind == .mpv else { return }
                NowPlayingController.shared.update(position: self.position, duration: self.duration, paused: paused)
                self.keepScreenAwake(!paused)
            }
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
        guard !closed else { return }
        guard attemptIndex < plan.count, plan[attemptIndex] == attempt else { return }   // a stale engine's event
        switch event {
        case .started:
            watchdog?.cancel()
            withAnimation(Theme.Motion.content) { phase = .playing }
            loadSkipSegments()
            // The system player publishes Now Playing itself; libmpv needs us to.
            if engineKind == .mpv, let mpv { NowPlayingController.shared.begin(session: self, engine: mpv) }
            keepScreenAwake(true)
        case let .progress(position, duration):
            self.position = position
            if duration > 0 {
                self.duration = duration
                // Markers are matched against the file's length. A stream that is still being prepared
                // reports only what exists so far, so look again once the length has grown for real.
                if segmentsDuration == 0 || duration > segmentsDuration * 1.25 + 60 { loadSkipSegments() }
            }
            recordProgress(force: false)
            if engineKind == .mpv, let mpv {
                NowPlayingController.shared.update(position: position, duration: self.duration, paused: mpv.isPaused)
            }
            // Up Next starts when the closing credits begin, else in the last 25 s, and only once the
            // duration has settled (see UpNextPolicy).
            // Seeking back well before the end takes back "Watch Credits": the end is new again.
            if upNextDeclined, self.duration > 0, position < self.duration * 0.75 { upNextDeclined = false }
            if nextEpisode != nil, upNextCountdown == nil, !upNextDeclined, phase == .playing,
               upNextPolicy.shouldStart(position: position, duration: self.duration, credits: skipSegments.filter { !dismissedSegments.contains($0) }) {
                startUpNextCountdown()
            }
            updateAction()
        case let .buffering(buffering):
            isBuffering = buffering
        case .ended:
            recordProgress(force: true, finished: true)
            // After "Watch Credits" (or with nothing after this), the end of the episode closes the player
            // and returns to the page it was opened from; otherwise Up Next carries on.
            if nextEpisode != nil, !upNextDeclined { playNext() } else { onFinished?() }
        case .failed:
            advance()
        }
    }

    // MARK: Screen

    /// The screensaver (Apple TV) and auto-lock (iPhone, iPad) must not start while a video plays. The
    /// system player handles this for itself; libmpv draws with Metal, so the app has to say so, as VLC
    /// and Infuse do. Paused, the screensaver may come back.
    private func keepScreenAwake(_ awake: Bool) {
        #if os(iOS) || os(tvOS)
        UIApplication.shared.isIdleTimerDisabled = awake
        #endif
    }

    // MARK: Skip Intro / Next Episode

    private func loadSkipSegments() {
        guard meta.type == "series" || meta.type == "anime" || meta.type == "movie", duration > 0 else { return }
        segmentsDuration = duration
        segmentsTask?.cancel()
        let metaID = meta.id, season = video?.season, episode = video?.episode, length = duration
        let videoID = video?.id
        let proxy = app?.cloud?.base
        segmentsTask = Task { [weak self] in
            var found = await SkipSegmentService(proxy: proxy).segments(metaID: metaID, season: season, episode: episode, duration: length)
            if found.isEmpty, let chapters = self?.mpv?.chapters(), !chapters.isEmpty {
                found = SkipSegmentService.fromChapters(chapters, duration: length)
            }
            guard !Task.isCancelled, let self, self.video?.id == videoID else { return }
            self.skipSegments = found
            self.updateAction()
        }
    }

    private func updateAction() {
        let next: PlayerAction?
        if let countdown = upNextCountdown, nextEpisode != nil {
            next = .nextEpisode(countdown: countdown)
        } else if upNextDeclined, nextEpisode != nil {
            next = .nextEpisode(countdown: nil)
        } else if let segment = skipSegments.first(where: { $0.isActive(at: position) && !dismissedSegments.contains($0) }) {
            // Closing credits offer the next episode; anything else (opening credits too) offers a skip.
            let closing = segment.kind == .credits && duration > 0 && segment.start >= duration * 0.6
            next = closing && nextEpisode != nil ? .nextEpisode(countdown: nil) : .skip(segment)
        } else {
            next = nil
        }
        if next != action { withAnimation(Theme.Motion.content) { action = next } }
    }

    /// The button was pressed.
    func performAction() {
        switch action {
        case let .skip(segment):
            dismissedSegments.insert(segment)
            engine?.seek(to: min(segment.end, max(duration - 1, 0)))
            action = nil
        case .nextEpisode:
            playNext()
        case nil:
            break
        }
    }

    var canPlayNext: Bool { nextEpisode != nil }

    // MARK: Progress

    private func recordProgress(force: Bool, finished: Bool = false) {
        guard let app, duration > 0, phase == .playing || finished else { return }
        guard force || abs(position - lastRecorded) >= 10 else { return }
        lastRecorded = position
        app.recordProgress(meta, videoID: video?.id, position: finished ? duration : position, duration: duration,
                           upNext: nextEpisode?.id)
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
        // Long enough that a scene after the credits isn't cut off before the viewer can say "Watch Credits".
        upNextCountdown = 15
        countdownTask = Task { [weak self] in
            while let self, let remaining = self.upNextCountdown, remaining > 0, !Task.isCancelled {
                self.updateAction()
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
        // The viewer said "not now": keep watching the credits (and any scene after them) without being
        // asked again, with Next Episode still there to press.
        upNextDeclined = true
        for segment in skipSegments where segment.kind == .credits { dismissedSegments.insert(segment) }
        updateAction()
    }

    func playNext() {
        guard !closed, let next = nextEpisode else { return }
        recordProgress(force: true, finished: true)
        countdownTask?.cancel()
        segmentsTask?.cancel()
        upNextCountdown = nil
        upNextDeclined = false
        upNextPolicy.reset()
        segmentsDuration = 0
        skipSegments = []
        dismissedSegments = []
        action = nil
        video = next
        resumeAt = 0
        position = 0
        duration = 0
        lastRecorded = 0
        updateNextEpisode()
        if engineKind == .mpv { NowPlayingController.shared.refreshMetadata() }   // the new episode's title and art
        Task { await resolveAndPlay() }
    }
}
