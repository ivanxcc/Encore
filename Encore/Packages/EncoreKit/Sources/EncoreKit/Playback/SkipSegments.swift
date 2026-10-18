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

    public init(http: HTTPClient = HTTPClient()) { self.http = http }

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

    struct IntroDBResponse: Decodable {
        struct Span: Decodable { let start_ms: Int?; let end_ms: Int? }
        let intro: [Span]?
        let recap: [Span]?
        let credits: [Span]?
        let preview: [Span]?
    }

    func theIntroDB(imdbID: String, season: Int?, episode: Int?, duration: TimeInterval) async -> [SkipSegment] {
        var components = URLComponents(string: "https://api.theintrodb.org/v3/media")!
        var items = [URLQueryItem(name: "imdb_id", value: imdbID)]
        if let season, let episode {
            items += [URLQueryItem(name: "season", value: String(season)), URLQueryItem(name: "episode", value: String(episode))]
        }
        if duration > 0 { items.append(URLQueryItem(name: "duration_ms", value: String(Int(duration * 1000)))) }
        components.queryItems = items
        guard let url = components.url,
              let response = try? await http.get(url, as: IntroDBResponse.self, timeout: 6) else { return [] }
        func spans(_ list: [IntroDBResponse.Span]?, _ kind: SkipSegment.Kind) -> [SkipSegment] {
            (list ?? []).compactMap { span in
                let start = Double(span.start_ms ?? 0) / 1000
                let end = span.end_ms.map { Double($0) / 1000 } ?? duration
                return end > start + 2 ? SkipSegment(kind: kind, start: start, end: end) : nil
            }
        }
        return Self.normalized(spans(response.intro, .intro) + spans(response.recap, .recap)
                               + spans(response.credits, .credits) + spans(response.preview, .preview))
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
        return Self.normalized((response.results ?? []).compactMap { result in
            let kind: SkipSegment.Kind
            switch result.skipType {
            case "op": kind = .intro
            case "ed": kind = .credits
            case "recap": kind = .recap
            default: return nil
            }
            return SkipSegment(kind: kind, start: result.interval.startTime, end: result.interval.endTime)
        })
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
        return normalized(segments)
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
