import Foundation

/// Talks the Stremio add-on protocol to every installed add-on.
///
/// Every fan-out is bounded per add-on: a slow or dead add-on costs at most its own timeout and never
/// blocks the others. That one rule is what keeps screens responsive with a dozen add-ons installed.
public struct AddonService: Sendable {
    public let http: HTTPClient
    public var perAddonTimeout: TimeInterval

    public init(http: HTTPClient = HTTPClient(), perAddonTimeout: TimeInterval = 12) {
        self.http = http
        self.perAddonTimeout = perAddonTimeout
    }

    // MARK: Manifest

    /// Install flow: accepts `stremio://` links and bare base URLs as well as manifest URLs.
    public func fetchAddon(from raw: String) async throws -> Addon {
        guard let url = Self.normalizedManifestURL(raw) else { throw HTTPError.invalidResponse }
        let manifest = try await http.get(url, as: AddonManifest.self, timeout: perAddonTimeout)
        return Addon(transportURL: url, manifest: manifest)
    }

    public static func normalizedManifestURL(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("stremio://") { text = "https://" + text.dropFirst("stremio://".count) }
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text), components.host?.isEmpty == false,
              ["http", "https"].contains(components.scheme?.lowercased() ?? "") else { return nil }
        if !components.path.hasSuffix("manifest.json") {
            components.path = (components.path.hasSuffix("/") ? components.path : components.path + "/") + "manifest.json"
        }
        return components.url
    }

    // MARK: Catalogs

    /// Rows for Home: every catalog that needs no input, in add-on order.
    public static func homeCatalogs(from addons: [Addon]) -> [CatalogRef] {
        addons.flatMap { addon in
            addon.manifest.catalogs.filter { !$0.hasRequiredExtra }.map { CatalogRef(addon: addon, catalog: $0) }
        }
    }

    public func catalog(_ ref: CatalogRef, skip: Int = 0, genre: String? = nil) async throws -> [MetaPreview] {
        var extra: [(String, String)] = []
        if let genre { extra.append(("genre", genre)) }
        if skip > 0 { extra.append(("skip", String(skip))) }
        let url = ref.addon.resourceURL("catalog", type: ref.catalog.type, id: ref.catalog.id, extra: extra)
        let response = try await http.get(url, as: CatalogResponse.self, timeout: perAddonTimeout)
        return Self.dedupe(response.metas?.compactMap(\.value) ?? [])
    }

    /// Search across every catalog that supports it, results grouped per catalog.
    /// - Parameter onPartial: called with the results so far each time another add-on answers, so a search
    ///   shows its first results in a moment instead of waiting for the slowest add-on.
    public func search(_ query: String, in addons: [Addon],
                       onPartial: (@Sendable ([(CatalogRef, [MetaPreview])]) async -> Void)? = nil) async -> [(CatalogRef, [MetaPreview])] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let refs = addons.flatMap { addon in
            addon.manifest.catalogs.filter(\.supportsSearch).map { CatalogRef(addon: addon, catalog: $0) }
        }
        let http = self.http, timeout = perAddonTimeout
        return await withTaskGroup(of: (Int, CatalogRef, [MetaPreview]).self) { group in
            for (index, ref) in refs.enumerated() {
                group.addTask {
                    let url = ref.addon.resourceURL("catalog", type: ref.catalog.type, id: ref.catalog.id,
                                                    extra: [("search", trimmed)])
                    let metas = (try? await http.get(url, as: CatalogResponse.self, timeout: timeout))?
                        .metas?.compactMap(\.value) ?? []
                    return (index, ref, metas)
                }
            }
            var results: [(Int, CatalogRef, [MetaPreview])] = []
            // Smart search first, then add-on order.
            func ordered() -> [(CatalogRef, [MetaPreview])] {
                results
                    .sorted { ($0.1.isSmartSearch ? 0 : 1, $0.0) < ($1.1.isSmartSearch ? 0 : 1, $1.0) }
                    .map { ($0.1, Self.dedupe($0.2)) }
            }
            for await result in group where !result.2.isEmpty {
                results.append(result)
                if let onPartial, !Task.isCancelled { await onPartial(ordered()) }
            }
            return ordered()
        }
    }

    // MARK: Meta

    /// The first add-on (in install order) that answers with a meta wins, as in Stremio.
    public func meta(type: String, id: String, in addons: [Addon]) async throws -> MetaDetail {
        for addon in addons where addon.manifest.supports("meta", type: type, id: id) {
            let url = addon.resourceURL("meta", type: type, id: id)
            if let meta = try? await http.get(url, as: MetaResponse.self, timeout: perAddonTimeout).meta {
                return meta
            }
        }
        throw HTTPError.status(404)
    }

    // MARK: Streams

    /// Ask every stream add-on at once. Groups arrive in add-on order; empty and failed ones are dropped.
    /// `onPartial` reports each group as it lands so the source list can fill in progressively.
    public func streams(type: String, id: String, in addons: [Addon],
                        onPartial: (@Sendable ([StreamGroup]) async -> Void)? = nil) async -> [StreamGroup] {
        let candidates = addons.enumerated().filter { $0.element.manifest.supports("stream", type: type, id: id) }
        let http = self.http, timeout = perAddonTimeout
        return await withTaskGroup(of: (Int, StreamGroup?).self) { group in
            for (index, addon) in candidates {
                group.addTask {
                    let url = addon.resourceURL("stream", type: type, id: id)
                    guard let response = try? await http.get(url, as: StreamsResponse.self, timeout: timeout) else {
                        return (index, nil)
                    }
                    let streams = response.streams?.compactMap(\.value) ?? []
                    return (index, streams.isEmpty ? nil : StreamGroup(addon: addon, streams: streams))
                }
            }
            var landed: [(Int, StreamGroup)] = []
            for await (index, result) in group {
                guard let result else { continue }
                landed.append((index, result))
                landed.sort { $0.0 < $1.0 }
                await onPartial?(landed.map(\.1))
            }
            return landed.map(\.1)
        }
    }

    public func subtitles(type: String, id: String, in addons: [Addon]) async -> [Subtitle] {
        let candidates = addons.filter { $0.manifest.supports("subtitles", type: type, id: id) }
        let http = self.http, timeout = perAddonTimeout
        return await withTaskGroup(of: [Subtitle].self) { group in
            for addon in candidates {
                group.addTask {
                    let url = addon.resourceURL("subtitles", type: type, id: id)
                    return (try? await http.get(url, as: SubtitlesResponse.self, timeout: timeout))?
                        .subtitles?.compactMap(\.value) ?? []
                }
            }
            var all: [Subtitle] = []
            for await batch in group { all += batch }
            var seen = Set<URL>()
            return all.filter { seen.insert($0.url).inserted }
        }
    }

    static func dedupe(_ metas: [MetaPreview]) -> [MetaPreview] {
        var seen = Set<String>()
        return metas.filter { seen.insert($0.type + ":" + $0.id).inserted }
    }
}
