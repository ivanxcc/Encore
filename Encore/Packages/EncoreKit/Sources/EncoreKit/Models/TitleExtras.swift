import Foundation

/// What Encore Cloud adds to a title from TMDB: the cast with photos, original-resolution artwork, the
/// tagline, and the age rating. Every field is optional; Cinemeta alone still renders a full page.
public struct TitleExtras: Codable, Hashable, Sendable {
    public struct Person: Codable, Hashable, Identifiable, Sendable {
        public var name: String
        public var character: String?
        public var photo: URL?
        public var id: String { name + "|" + (character ?? "") }

        public init(name: String, character: String? = nil, photo: URL? = nil) {
            self.name = name; self.character = character; self.photo = photo
        }
    }

    public struct Credit: Codable, Hashable, Sendable {
        public var name: String
        public var job: String
    }

    /// An official trailer (YouTube video id), the best TMDB has.
    public struct Trailer: Codable, Hashable, Sendable {
        public var site: String
        public var key: String
        public var name: String?
        public init(site: String = "YouTube", key: String, name: String? = nil) { self.site = site; self.key = key; self.name = name }
    }

    public var trailer: Trailer?
    public var tmdbId: Int?
    public var backdrop: URL?
    public var logo: URL?
    public var tagline: String?
    public var cast: [Person]
    public var crew: [Credit]
    public var certification: String?
    /// A movie's exact length in minutes (TMDB); nil for shows, whose episodes vary.
    public var runtime: Int?

    public init(cast: [Person] = [], crew: [Credit] = [], backdrop: URL? = nil, logo: URL? = nil,
                tagline: String? = nil, certification: String? = nil, tmdbId: Int? = nil) {
        self.cast = cast; self.crew = crew; self.backdrop = backdrop; self.logo = logo
        self.tagline = tagline; self.certification = certification; self.tmdbId = tmdbId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tmdbId = try? c.decodeIfPresent(Int.self, forKey: .tmdbId)
        backdrop = c.url(.backdrop)
        logo = c.url(.logo)
        tagline = try? c.decodeIfPresent(String.self, forKey: .tagline)
        cast = (try? c.decodeIfPresent([Lossy<Person>].self, forKey: .cast))?.compactMap(\.value) ?? []
        crew = (try? c.decodeIfPresent([Lossy<Credit>].self, forKey: .crew))?.compactMap(\.value) ?? []
        certification = try? c.decodeIfPresent(String.self, forKey: .certification)
        trailer = try? c.decodeIfPresent(Trailer.self, forKey: .trailer)
        runtime = try? c.decodeIfPresent(Int.self, forKey: .runtime)
    }

    /// Names only (Cinemeta), for when the cloud has no TMDB key: the page still shows the cast.
    public static func names(_ cast: [String]?) -> [Person] {
        (cast ?? []).map { Person(name: $0) }
    }
}

/// A title trending this week (TMDB), already mapped to its IMDb id so Stremio add-ons can play it.
public struct TrendingTitle: Codable, Hashable, Sendable {
    public var imdbId: String
    public var type: String
    public var name: String
    public var backdrop: URL?
    public var logo: URL?
    public var overview: String?
    public var year: String?
    public var genres: [String]?
    public var rating: Double?

    public var preview: MetaPreview {
        MetaPreview(id: imdbId, type: type, name: name, background: backdrop, logo: logo, description: overview,
                    releaseInfo: year, imdbRating: rating.map { String(format: "%.1f", $0) }, genres: genres)
    }
}
