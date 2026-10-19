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

    /// Add-ons hand out metahub artwork at modest sizes (Cinemeta's backdrops are "medium"). On a 4K TV
    /// that is visibly soft, so backdrops and logos are asked for at "large", and posters at least "medium".
    public static func sharpened(_ url: URL?) -> URL? {
        guard let url, url.host == "images.metahub.space" else { return url }
        var parts = url.pathComponents   // ["/", "background", "medium", "tt…", "img"]
        guard parts.count >= 3 else { return url }
        switch parts[1] {
        case "background", "logo": parts[2] = Size.large.rawValue
        case "poster" where parts[2] == Size.small.rawValue: parts[2] = Size.medium.rawValue
        default: return url
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = "/" + parts.dropFirst().joined(separator: "/")
        return components?.url ?? url
    }
}

public extension MetaPreview {
    var backdropURL: URL? { ArtworkURLs.sharpened(background) ?? ArtworkURLs.backdrop(for: id) ?? poster }
    var logoURL: URL? { ArtworkURLs.sharpened(logo) ?? ArtworkURLs.logo(for: id, size: .large) }
    var posterURL: URL? { ArtworkURLs.sharpened(poster) ?? ArtworkURLs.poster(for: id) }
}

public extension MetaDetail {
    var backdropURL: URL? { ArtworkURLs.sharpened(background) ?? ArtworkURLs.backdrop(for: id) ?? poster }
    var logoURL: URL? { ArtworkURLs.sharpened(logo) ?? ArtworkURLs.logo(for: id, size: .large) }
}

public extension StremioLibraryItem {
    var backdropURL: URL? { ArtworkURLs.backdrop(for: id) ?? poster }
    var preview: MetaPreview { MetaPreview(id: id, type: type, name: name, poster: poster) }
}
