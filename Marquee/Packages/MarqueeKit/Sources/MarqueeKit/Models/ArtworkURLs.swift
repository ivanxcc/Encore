import Foundation

/// Artwork fallbacks for IMDb-id titles from Stremio's public metahub image service. Catalog entries and
/// library items often carry only a poster; these give every title a wide backdrop and a logo, which is
/// what makes the hero and landscape shelves look right.
public enum ArtworkURLs {
    public enum Size: String, Sendable { case small, medium, large }

    static func imdbID(_ id: String) -> String? {
        let base = id.split(separator: ":").first.map(String.init) ?? id
        guard base.hasPrefix("tt"), base.count > 2, base.dropFirst(2).allSatisfy(\.isNumber) else { return nil }
        return base
    }

    public static func backdrop(for id: String, size: Size = .large) -> URL? {
        imdbID(id).flatMap { URL(string: "https://images.metahub.space/background/\(size.rawValue)/\($0)/img") }
    }

    public static func logo(for id: String, size: Size = .medium) -> URL? {
        imdbID(id).flatMap { URL(string: "https://images.metahub.space/logo/\(size.rawValue)/\($0)/img") }
    }

    public static func poster(for id: String, size: Size = .medium) -> URL? {
        imdbID(id).flatMap { URL(string: "https://images.metahub.space/poster/\(size.rawValue)/\($0)/img") }
    }
}

public extension MetaPreview {
    var backdropURL: URL? { background ?? ArtworkURLs.backdrop(for: id) ?? poster }
    var logoURL: URL? { logo ?? ArtworkURLs.logo(for: id) }
    var posterURL: URL? { poster ?? ArtworkURLs.poster(for: id) }
}

public extension MetaDetail {
    var backdropURL: URL? { background ?? ArtworkURLs.backdrop(for: id) ?? poster }
    var logoURL: URL? { logo ?? ArtworkURLs.logo(for: id) }
}

public extension LibraryItem {
    var backdropURL: URL? { ArtworkURLs.backdrop(for: id, size: .medium) ?? poster }
    var preview: MetaPreview { MetaPreview(id: id, type: type, name: name, poster: poster) }
}
