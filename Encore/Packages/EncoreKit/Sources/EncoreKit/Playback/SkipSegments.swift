import Foundation

/// A part of an episode a viewer usually skips.
public struct SkipSegment: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case intro, recap, credits, preview

        /// What the button says.
        public var actionTitle: String {
            switch self {
            case .intro: "Skip Intro"
            case .recap: "Skip Recap"
            case .credits: "Skip Credits"
            case .preview: "Skip Preview"
            }
        }
    }

    public var kind: Kind
    public var start: TimeInterval
    public var end: TimeInterval

    public init(kind: Kind, start: TimeInterval, end: TimeInterval) {
        self.kind = kind; self.start = start; self.end = end
    }

    /// Whether the button should be on screen at `position`. It disappears a moment before the segment
    /// ends so it never jumps the viewer a fraction of a second forward.
    public func isActive(at position: TimeInterval) -> Bool {
        position >= start && position < end - 1.5
    }
}

/// Finds intro / recap / credits markers: the community databases first (TheIntroDB for movies and TV,
/// AniSkip for anime), then chapter titles embedded in the file. Every lookup is best effort and bounded;
/// no markers simply means no button.
public struct SkipSegmentService: Sendable {
    public let http: HTTPClient
    /// Encore Cloud, which asks TheIntroDB on the app's behalf: its bot protection can turn away a TV or
    /// a phone, but not a request from Cloudflare's own network.
    public let proxy: URL?

    public init(http: HTTPClient = HTTPClient(), proxy: URL? = nil) { self.http = http; self.proxy = proxy }

    /// - Parameters:
    ///   - metaID: the title id (`tt…`, `kitsu:…`, `mal:…`).
    ///   - season/episode: nil for movies.
    ///   - duration: the playing file's duration, used to pick the matching release cut and to close
    ///     open-ended segments.
    public func segments(metaID: String, season: Int?, episode: Int?, duration: TimeInterval) async -> [SkipSegment] {
        if metaID.range(of: #"^tt\d{5,9}$"#, options: .regularExpression) != nil {
            return await theIntroDB(imdbID: metaID, season: season, episode: episode, duration: duration)
        }
        if metaID.hasPrefix("kitsu:") || metaID.hasPrefix("mal:") {
            return await aniSkip(metaID: metaID, episode: episode, duration: duration)
        }
        return []
    }

    // MARK: TheIntroDB

    /// One marker from TheIntroDB, read leniently: millisecond or second fields under any of the names
    /// the API has used, and a missing start or end kept as missing (not zero), because a credits marker
    /// without a start must never be read as "credits from 0:00".
    struct IntroDBSpan: Decodable {
        let start: TimeInterval?
        let end: TimeInterval?

        private struct Key: CodingKey {
            var stringValue: String; var intValue: Int? { nil }
            init(_ s: String) { stringValue = s }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            func number(_ names: [String]) -> Double? {
                for name in names {
                    if let v = try? c.decodeIfPresent(Double.self, forKey: Key(name)) { return v }
                    if let s = try? c.decodeIfPresent(String.self, forKey: Key(name)), let v = Double(s) { return v }
                }
                return nil
            }
            start = number(["start_ms", "startMs", "start_time_ms"]).map { $0 / 1000 } ?? number(["start", "start_sec", "startTime"])
            end = number(["end_ms", "endMs", "end_time_ms"]).map { $0 / 1000 } ?? number(["end", "end_sec", "endTime"])
        }

        init(start: TimeInterval?, end: TimeInterval?) { self.start = start; self.end = end }
    }

    struct IntroDBResponse: Decodable {
        let intro: [IntroDBSpan]
        let recap: [IntroDBSpan]
        let credits: [IntroDBSpan]
        let preview: [IntroDBSpan]

        private enum CodingKeys: String, CodingKey { case intro, recap, credits, preview }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Each kind may be a list of markers or a single marker.
            func spans(_ key: CodingKeys) -> [IntroDBSpan] {
                if let list = try? c.decodeIfPresent([IntroDBSpan].self, forKey: key) { return list }
                if let one = try? c.decodeIfPresent(IntroDBSpan.self, forKey: key) { return [one] }
                return []
            }
            intro = spans(.intro); recap = spans(.recap); credits = spans(.credits); preview = spans(.preview)
        }
    }

    func theIntroDB(imdbID: String, season: Int?, episode: Int?, duration: TimeInterval) async -> [SkipSegment] {
        var items: [URLQueryItem] = []
        if let season, let episode {
            items += [URLQueryItem(name: "season", value: String(season)), URLQueryItem(name: "episode", value: String(episode))]
        }
        if duration > 0 { items.append(URLQueryItem(name: "duration_ms", value: String(Int(duration * 1000)))) }

        var urls: [URL] = []
        if let proxy, var viaCloud = URLComponents(url: proxy.appendingPathComponent("v1/skip"), resolvingAgainstBaseURL: false) {
            viaCloud.queryItems = [URLQueryItem(name: "imdb", value: imdbID)] + items
            if let url = viaCloud.url { urls.append(url) }
        }
        var direct = URLComponents(string: "https://api.theintrodb.org/v3/media")!
        direct.queryItems = [URLQueryItem(name: "imdb_id", value: imdbID)] + items
        if let url = direct.url { urls.append(url) }

        for url in urls {
            if let response = try? await http.get(url, as: IntroDBResponse.self, timeout: 6) {
                return Self.segments(from: response, duration: duration)
            }
        }
        return []
    }

    static func segments(from response: IntroDBResponse, duration: TimeInterval) -> [SkipSegment] {
        func make(_ spans: [IntroDBSpan], _ kind: SkipSegment.Kind) -> [SkipSegment] {
            spans.compactMap { span in
                switch kind {
                case .intro, .recap:
                    // An intro or recap may start at the very beginning (no start), but must say where it ends.
                    guard let end = span.end else { return nil }
                    return SkipSegment(kind: kind, start: span.start ?? 0, end: end)
                case .credits, .preview:
                    // Credits and previews may run to the end (no end), but must say where they start.
                    guard let start = span.start else { return nil }
                    return SkipSegment(kind: kind, start: start, end: span.end ?? duration)
                }
            }
        }
        return sanitized(make(response.intro, .intro) + make(response.recap, .recap)
                         + make(response.credits, .credits) + make(response.preview, .preview), duration: duration)
    }

    /// Markers that cannot be right for this file are dropped, so a bad entry never puts "Skip Credits"
    /// on the first minute: intros and recaps are short and early; credits and previews are late.
    static func sanitized(_ segments: [SkipSegment], duration: TimeInterval) -> [SkipSegment] {
        normalized(segments.compactMap { segment in
            var segment = segment
            if duration > 0 {
                segment.end = min(segment.end, duration)
            }
            let length = segment.end - segment.start
            guard length > 2 else { return nil }
            switch segment.kind {
            case .intro, .recap:
                guard length <= 300 else { return nil }
                if duration > 0, segment.start > duration * 0.5 { return nil }
            case .credits, .preview:
                guard length <= 900 else { return nil }
                if duration > 0, segment.start < duration * 0.5 {
                    // "Credits" near the start are opening credits: offer them as an intro.
                    guard segment.kind == .credits, length <= 300 else { return nil }
                    segment = SkipSegment(kind: .intro, start: segment.start, end: segment.end)
                }
            }
            return segment
        })
    }

    // MARK: AniSkip

    struct AniSkipResponse: Decodable {
        struct Result: Decodable {
            struct Interval: Decodable { let startTime: Double; let endTime: Double }
            let interval: Interval
            let skipType: String
        }
        let found: Bool?
        let results: [Result]?
    }

    func aniSkip(metaID: String, episode: Int?, duration: TimeInterval) async -> [SkipSegment] {
        guard let episode, episode > 0, duration > 0, let mal = await malID(for: metaID) else { return [] }
        var components = URLComponents(string: "https://api.aniskip.com/v2/skip-times/\(mal)/\(episode)")!
        components.queryItems = [URLQueryItem(name: "types[]", value: "op"), URLQueryItem(name: "types[]", value: "ed"),
                                 URLQueryItem(name: "types[]", value: "recap"),
                                 URLQueryItem(name: "episodeLength", value: String(Int(duration)))]
        guard let url = components.url,
              let response = try? await http.get(url, as: AniSkipResponse.self, timeout: 6),
              response.found == true else { return [] }
        return Self.sanitized((response.results ?? []).compactMap { result in
            let kind: SkipSegment.Kind
            switch result.skipType {
            case "op": kind = .intro
            case "ed": kind = .credits
            case "recap": kind = .recap
            default: return nil
            }
            return SkipSegment(kind: kind, start: result.interval.startTime, end: result.interval.endTime)
        }, duration: duration)
    }

    private func malID(for metaID: String) async -> Int? {
        let parts = metaID.split(separator: ":")
        guard parts.count >= 2, let id = Int(parts[1]) else { return nil }
        if parts[0] == "mal" { return id }
        struct Mappings: Decodable {
            struct Row: Decodable {
                struct Attributes: Decodable { let externalSite: String?; let externalId: String? }
                let attributes: Attributes
            }
            let data: [Row]
        }
        guard let url = URL(string: "https://kitsu.io/api/edge/anime/\(id)/mappings"),
              let mappings = try? await http.get(url, as: Mappings.self, timeout: 6) else { return nil }
        return mappings.data.first { $0.attributes.externalSite == "myanimelist/anime" }
            .flatMap { $0.attributes.externalId.flatMap(Int.init) }
    }

    // MARK: Chapters

    /// Markers from chapter titles embedded in the file ("Intro", "Opening", "OP", "Recap", "Credits",
    /// "Ending", "ED", "Preview"). Each chapter runs until the next one starts.
    public static func fromChapters(_ chapters: [(title: String, start: TimeInterval)], duration: TimeInterval) -> [SkipSegment] {
        let sorted = chapters.sorted { $0.start < $1.start }
        var segments: [SkipSegment] = []
        for (index, chapter) in sorted.enumerated() {
            let title = chapter.title.lowercased().trimmingCharacters(in: .whitespaces)
            let words = Set(title.split(whereSeparator: { !$0.isLetter }).map(String.init))
            let kind: SkipSegment.Kind?
            if title.contains("intro") || title.contains("opening") || words.contains("op") { kind = .intro }
            else if title.contains("recap") || title.contains("previously") { kind = .recap }
            else if title.contains("credit") || title.contains("ending") || title.contains("outro") || words.contains("ed") { kind = .credits }
            else if title.contains("preview") || title.contains("next time") { kind = .preview }
            else { kind = nil }
            guard let kind else { continue }
            let end = index + 1 < sorted.count ? sorted[index + 1].start : duration
            if end > chapter.start + 2 { segments.append(SkipSegment(kind: kind, start: chapter.start, end: end)) }
        }
        return sanitized(segments, duration: duration)
    }

    /// Sorted, deduplicated (one segment per kind and start), and never longer than the file.
    static func normalized(_ segments: [SkipSegment]) -> [SkipSegment] {
        var seen = Set<String>()
        return segments
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }
            .filter { seen.insert("\($0.kind.rawValue)@\(Int($0.start))").inserted }
    }
}

/// When to start the Next Episode countdown. The duration a player reports is not always the episode's:
/// a stream from a Stremio streaming server grows as it is prepared, so early on its "duration" is only
/// a few seconds ahead of the playhead. Up Next waits for a settled duration and a point that is
/// really the end of the episode.
public struct UpNextPolicy: Sendable {
    /// How long the reported duration must stay put before it is trusted.
    public var settleTime: TimeInterval = 15
    private var lastDuration: TimeInterval = 0
    private var durationSince: Date = .distantPast

    public init() {}

    /// Call on every progress tick; returns true when the countdown should start.
    public mutating func shouldStart(position: TimeInterval, duration: TimeInterval,
                                     credits: [SkipSegment], now: Date = Date()) -> Bool {
        if abs(duration - lastDuration) > 2 {
            lastDuration = duration
            durationSince = now
        }
        guard duration >= 300, now.timeIntervalSince(durationSince) >= settleTime else { return false }
        // Credits markers count only when they really are at the end (not "opening credits").
        let inCredits = credits.contains {
            $0.kind == .credits && $0.isActive(at: position) && $0.start >= duration * 0.6 && $0.end >= duration - 90
        }
        let nearEnd = duration - position < 25 && position >= duration * 0.8
        return inCredits || nearEnd
    }

    /// A new episode starts: forget the previous duration.
    public mutating func reset() { self = UpNextPolicy() }
}
