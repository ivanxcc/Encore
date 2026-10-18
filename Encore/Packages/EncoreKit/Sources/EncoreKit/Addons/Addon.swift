import Foundation

/// An installed add-on: where it lives plus its manifest.
public struct Addon: Codable, Hashable, Identifiable, Sendable {
    /// The manifest URL, the add-on's identity (two configurations of one add-on are two add-ons).
    public var transportURL: URL
    public var manifest: AddonManifest
    /// Official add-ons the account marks as protected (Cinemeta). Display only.
    public var isProtected: Bool

    public var id: String { transportURL.absoluteString }

    public init(transportURL: URL, manifest: AddonManifest, isProtected: Bool = false) {
        self.transportURL = transportURL; self.manifest = manifest; self.isProtected = isProtected
    }

    /// Everything before `/manifest.json`; every resource URL is built on it.
    public var baseURL: URL {
        var raw = transportURL.absoluteString
        if let query = raw.firstIndex(of: "?") { raw = String(raw[..<query]) }
        if raw.hasSuffix("/manifest.json") { raw.removeLast("/manifest.json".count) }
        while raw.hasSuffix("/") { raw.removeLast() }
        return URL(string: raw) ?? transportURL
    }

    /// `{base}/{resource}/{type}/{id}[/{extra}].json`, with each path segment percent-encoded per the
    /// protocol (ids such as `tt123:1:2` keep their colons; spaces and slashes are escaped).
    public func resourceURL(_ resource: String, type: String, id: String, extra: [(String, String)] = []) -> URL {
        var path = baseURL.absoluteString + "/" + resource + "/" + Self.segment(type) + "/" + Self.segment(id)
        if !extra.isEmpty {
            path += "/" + extra.map { Self.extraComponent($0.0) + "=" + Self.extraComponent($0.1) }.joined(separator: "&")
        }
        return URL(string: path + ".json")!
    }

    static let segmentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/?#%")
        return set
    }()

    static let extraAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func segment(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? raw
    }

    static func extraComponent(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: extraAllowed) ?? raw
    }
}

/// One Home/Discover row backed by an add-on catalog.
public struct CatalogRef: Hashable, Identifiable, Sendable {
    public var addon: Addon
    public var catalog: AddonManifest.Catalog

    public var id: String { addon.id + "|" + catalog.type + "|" + catalog.id }
    public var title: String {
        let name = catalog.name ?? catalog.id.capitalized
        return "\(name) \(catalog.type == "series" ? "Shows" : catalog.type == "movie" ? "Movies" : catalog.type.capitalized)"
    }
}

/// Streams from one add-on, kept together so the source list can show where each came from.
public struct StreamGroup: Hashable, Identifiable, Sendable {
    public var addon: Addon
    public var streams: [AddonStream]
    public var id: String { addon.id }
}
