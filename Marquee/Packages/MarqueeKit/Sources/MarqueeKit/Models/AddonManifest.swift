import Foundation

/// A Stremio add-on manifest (`/manifest.json`). Decoding is tolerant: add-ons in the wild omit
/// fields, use either string or object resources, and add vendor keys, and one malformed add-on
/// must never take down the rest of the app.
public struct AddonManifest: Codable, Hashable, Sendable {
    public var id: String
    public var version: String
    public var name: String
    public var description: String?
    public var logo: URL?
    public var background: URL?
    public var types: [String]
    public var resources: [Resource]
    public var catalogs: [Catalog]
    public var idPrefixes: [String]?
    public var behaviorHints: BehaviorHints?

    public struct BehaviorHints: Codable, Hashable, Sendable {
        public var adult: Bool?
        public var configurable: Bool?
        public var configurationRequired: Bool?
    }

    /// A resource is either a bare name ("stream") or an object narrowing types and id prefixes.
    public struct Resource: Codable, Hashable, Sendable {
        public var name: String
        public var types: [String]?
        public var idPrefixes: [String]?

        public init(name: String, types: [String]? = nil, idPrefixes: [String]? = nil) {
            self.name = name; self.types = types; self.idPrefixes = idPrefixes
        }

        public init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(), let name = try? single.decode(String.self) {
                self.init(name: name)
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(name: try c.decode(String.self, forKey: .name),
                      types: try c.decodeIfPresent([String].self, forKey: .types),
                      idPrefixes: try c.decodeIfPresent([String].self, forKey: .idPrefixes))
        }

        public func encode(to encoder: Encoder) throws {
            if types == nil && idPrefixes == nil {
                var single = encoder.singleValueContainer()
                try single.encode(name)
            } else {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(name, forKey: .name)
                try c.encodeIfPresent(types, forKey: .types)
                try c.encodeIfPresent(idPrefixes, forKey: .idPrefixes)
            }
        }

        private enum CodingKeys: String, CodingKey { case name, types, idPrefixes }
    }

    public struct Catalog: Codable, Hashable, Sendable {
        public var type: String
        public var id: String
        public var name: String?
        public var extra: [Extra]?

        public struct Extra: Codable, Hashable, Sendable {
            public var name: String
            public var isRequired: Bool?
            public var options: [String]?
        }

        /// Catalogs that need input (a search query, a genre) cannot be shown as a plain Home row.
        public var hasRequiredExtra: Bool { extra?.contains { $0.isRequired == true } ?? false }
        public var supportsSearch: Bool { extra?.contains { $0.name == "search" } ?? false }
        public var supportsSkip: Bool { extra?.contains { $0.name == "skip" } ?? false }
        public var genres: [String] { extra?.first { $0.name == "genre" }?.options ?? [] }
    }

    public init(id: String, version: String = "0.0.0", name: String, description: String? = nil,
                types: [String] = [], resources: [Resource] = [], catalogs: [Catalog] = [],
                idPrefixes: [String]? = nil) {
        self.id = id; self.version = version; self.name = name; self.description = description
        self.types = types; self.resources = resources; self.catalogs = catalogs; self.idPrefixes = idPrefixes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        version = (try? c.decode(String.self, forKey: .version)) ?? "0.0.0"
        name = (try? c.decode(String.self, forKey: .name)) ?? id
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        logo = (try? c.decodeIfPresent(String.self, forKey: .logo)).flatMap(URL.init(string:))
        background = (try? c.decodeIfPresent(String.self, forKey: .background)).flatMap(URL.init(string:))
        types = (try? c.decodeIfPresent([String].self, forKey: .types)) ?? []
        resources = Self.lossy(c, .resources)
        catalogs = Self.lossy(c, .catalogs)
        idPrefixes = try? c.decodeIfPresent([String].self, forKey: .idPrefixes)
        behaviorHints = try? c.decodeIfPresent(BehaviorHints.self, forKey: .behaviorHints)
    }

    private enum CodingKeys: String, CodingKey {
        case id, version, name, description, logo, background, types, resources, catalogs, idPrefixes, behaviorHints
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(version, forKey: .version)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(logo, forKey: .logo)
        try c.encodeIfPresent(background, forKey: .background)
        try c.encode(types, forKey: .types)
        try c.encode(resources, forKey: .resources)
        try c.encode(catalogs, forKey: .catalogs)
        try c.encodeIfPresent(idPrefixes, forKey: .idPrefixes)
        try c.encodeIfPresent(behaviorHints, forKey: .behaviorHints)
    }

    /// Decode an array keeping every element that decodes, dropping the ones that do not.
    private static func lossy<T: Decodable>(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [T] {
        (try? c.decodeIfPresent([Lossy<T>].self, forKey: key))?.compactMap(\.value) ?? []
    }

    /// Whether this add-on answers `resource` for an item of `type` with id `id`.
    public func supports(_ resource: String, type: String, id: String?) -> Bool {
        guard let entry = resources.first(where: { $0.name == resource }) else { return false }
        let typeList = entry.types ?? types
        guard typeList.isEmpty || typeList.contains(type) else { return false }
        guard let id, let prefixes = entry.idPrefixes ?? idPrefixes, !prefixes.isEmpty else { return true }
        return prefixes.contains { id.hasPrefix($0) }
    }
}

/// Wraps one array element so a single bad element is skipped instead of failing the whole array.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}
