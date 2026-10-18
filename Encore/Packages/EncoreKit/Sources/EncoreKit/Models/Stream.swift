import Foundation

/// One stream offered by an add-on (`streams[]`). A stream is playable through exactly one of:
/// a direct `url`, a torrent `infoHash` (needs a streaming server), or it is an external link.
public struct AddonStream: Codable, Hashable, Sendable {
    public var url: URL?
    public var infoHash: String?
    public var fileIdx: Int?
    public var externalUrl: URL?
    public var ytId: String?
    public var name: String?
    public var title: String?
    public var description: String?
    public var behaviorHints: BehaviorHints?
    public var subtitles: [Subtitle]?
    public var sources: [String]?

    public struct BehaviorHints: Codable, Hashable, Sendable {
        public var notWebReady: Bool?
        public var bingeGroup: String?
        public var filename: String?
        public var videoSize: Int64?
        public var proxyHeaders: ProxyHeaders?

        public struct ProxyHeaders: Codable, Hashable, Sendable {
            public var request: [String: String]?
        }
    }

    /// The text add-ons put their release details in (Torrentio uses `title`, newer add-ons `description`).
    public var details: String { [description, title].compactMap { $0 }.first ?? "" }

    public init(url: URL? = nil, infoHash: String? = nil, fileIdx: Int? = nil, name: String? = nil,
                title: String? = nil, description: String? = nil, behaviorHints: BehaviorHints? = nil) {
        self.url = url; self.infoHash = infoHash; self.fileIdx = fileIdx; self.name = name
        self.title = title; self.description = description; self.behaviorHints = behaviorHints
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = c.url(.url)
        infoHash = (try? c.decodeIfPresent(String.self, forKey: .infoHash))?.lowercased()
        fileIdx = c.intish(.fileIdx)
        externalUrl = c.url(.externalUrl)
        ytId = try? c.decodeIfPresent(String.self, forKey: .ytId)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        behaviorHints = try? c.decodeIfPresent(BehaviorHints.self, forKey: .behaviorHints)
        subtitles = (try? c.decodeIfPresent([Lossy<Subtitle>].self, forKey: .subtitles))?.compactMap(\.value)
        sources = try? c.decodeIfPresent([String].self, forKey: .sources)
    }
}

public struct Subtitle: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var url: URL
    public var lang: String

    public init(id: String, url: URL, lang: String) { self.id = id; self.url = url; self.lang = lang }
}

/// Envelopes for the add-on HTTP responses.
struct CatalogResponse: Decodable { let metas: [Lossy<MetaPreview>]? }
struct MetaResponse: Decodable { let meta: MetaDetail? }
struct StreamsResponse: Decodable { let streams: [Lossy<AddonStream>]? }
struct SubtitlesResponse: Decodable { let subtitles: [Lossy<Subtitle>]? }
