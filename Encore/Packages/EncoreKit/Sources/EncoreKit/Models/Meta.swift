import Foundation

/// A catalog entry (`metas[]` in a catalog response). Only `id` and `type` are guaranteed.
public struct MetaPreview: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var type: String
    public var name: String
    public var poster: URL?
    public var background: URL?
    public var logo: URL?
    public var description: String?
    public var releaseInfo: String?
    public var imdbRating: String?
    public var genres: [String]?

    public init(id: String, type: String, name: String, poster: URL? = nil, background: URL? = nil,
                logo: URL? = nil, description: String? = nil, releaseInfo: String? = nil,
                imdbRating: String? = nil, genres: [String]? = nil) {
        self.id = id; self.type = type; self.name = name; self.poster = poster; self.background = background
        self.logo = logo; self.description = description; self.releaseInfo = releaseInfo
        self.imdbRating = imdbRating; self.genres = genres
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(String.self, forKey: .type)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        poster = c.url(.poster); background = c.url(.background); logo = c.url(.logo)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        releaseInfo = c.stringish(.releaseInfo)
        imdbRating = c.stringish(.imdbRating)
        genres = try? c.decodeIfPresent([String].self, forKey: .genres)
    }
}

/// Full detail for one title (`meta` in a meta response).
public struct MetaDetail: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var type: String
    public var name: String
    public var poster: URL?
    public var background: URL?
    public var logo: URL?
    public var description: String?
    public var releaseInfo: String?
    public var imdbRating: String?
    public var runtime: String?
    public var genres: [String]?
    public var cast: [String]?
    public var director: [String]?
    public var videos: [Video]
    public var trailers: [Trailer]?

    public struct Trailer: Codable, Hashable, Sendable {
        public var source: String
        public var type: String?
    }

    public var preview: MetaPreview {
        MetaPreview(id: id, type: type, name: name, poster: poster, background: background, logo: logo,
                    description: description, releaseInfo: releaseInfo, imdbRating: imdbRating, genres: genres)
    }

    /// Seasons in display order, specials (season 0) last.
    public var seasons: [Int] {
        let all = Set(videos.compactMap(\.season))
        return all.filter { $0 > 0 }.sorted() + (all.contains(0) ? [0] : [])
    }

    public func episodes(inSeason season: Int) -> [Video] {
        videos.filter { $0.season == season }.sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }
    }

    public init(id: String, type: String, name: String, videos: [Video] = []) {
        self.id = id; self.type = type; self.name = name; self.videos = videos
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(String.self, forKey: .type)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        poster = c.url(.poster); background = c.url(.background); logo = c.url(.logo)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        releaseInfo = c.stringish(.releaseInfo)
        imdbRating = c.stringish(.imdbRating)
        runtime = c.stringish(.runtime)
        genres = try? c.decodeIfPresent([String].self, forKey: .genres)
        cast = try? c.decodeIfPresent([String].self, forKey: .cast)
        director = try? c.decodeIfPresent([String].self, forKey: .director)
        videos = (try? c.decodeIfPresent([Lossy<Video>].self, forKey: .videos))?.compactMap(\.value) ?? []
        trailers = try? c.decodeIfPresent([Trailer].self, forKey: .trailers)
    }
}

/// One playable unit of a title: an episode of a series, or the single video of a movie.
public struct Video: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var season: Int?
    public var episode: Int?
    public var released: Date?
    public var thumbnail: URL?
    public var overview: String?

    public var episodeLabel: String? {
        guard let season, let episode else { return nil }
        return "S\(season), E\(episode)"
    }

    public init(id: String, title: String, season: Int? = nil, episode: Int? = nil) {
        self.id = id; self.title = title; self.season = season; self.episode = episode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        // Cinemeta uses `name`, the protocol docs say `title`; accept either.
        title = (try? c.decode(String.self, forKey: .title))
            ?? (try? c.decode(String.self, forKey: .name)) ?? ""
        season = c.intish(.season)
        episode = c.intish(.episode) ?? c.intish(.number)
        released = (try? c.decodeIfPresent(String.self, forKey: .released)).flatMap(ISO8601.parse)
        thumbnail = c.url(.thumbnail)
        overview = (try? c.decodeIfPresent(String.self, forKey: .overview))
            ?? (try? c.decodeIfPresent(String.self, forKey: .description))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(season, forKey: .season)
        try c.encodeIfPresent(episode, forKey: .episode)
        try c.encodeIfPresent(released.map(ISO8601.format), forKey: .released)
        try c.encodeIfPresent(thumbnail, forKey: .thumbnail)
        try c.encodeIfPresent(overview, forKey: .overview)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, name, season, episode, number, released, thumbnail, overview, description
    }
}

enum ISO8601 {
    static func parse(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }

    static func format(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}

extension KeyedDecodingContainer {
    func url(_ key: Key) -> URL? {
        guard let raw = try? decodeIfPresent(String.self, forKey: key), !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    /// Add-ons send some fields as either strings or numbers.
    func stringish(_ key: Key) -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        if let d = try? decodeIfPresent(Double.self, forKey: key) {
            return d.rounded() == d ? String(Int(d)) : String(d)
        }
        return nil
    }

    func intish(_ key: Key) -> Int? {
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Int(s) }
        return nil
    }
}
