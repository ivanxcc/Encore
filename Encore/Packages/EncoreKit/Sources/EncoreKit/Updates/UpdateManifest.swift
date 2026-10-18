import Foundation

/// `encore-update.json`, published with every release. The Mac app reads the latest one to offer an
/// in-place update; the SHA-256 lets it refuse a download that is not byte-for-byte the released file.
public struct UpdateManifest: Codable, Hashable, Sendable {
    public var version: String
    public var build: Int
    public var url: URL
    public var sha256: String
    public var notes: String?
    public var releasePage: URL?
    public var minimumSystemVersion: String?

    public init(version: String, build: Int, url: URL, sha256: String, notes: String? = nil,
                releasePage: URL? = nil, minimumSystemVersion: String? = nil) {
        self.version = version; self.build = build; self.url = url; self.sha256 = sha256
        self.notes = notes; self.releasePage = releasePage; self.minimumSystemVersion = minimumSystemVersion
    }

    /// Releases are numbered by build; a higher build is newer regardless of the marketing version.
    public func isNewer(thanBuild installed: Int) -> Bool { build > installed }

    /// The stable URL of the newest manifest for a GitHub repository ("owner/name").
    public static func latestURL(repository: String) -> URL? {
        URL(string: "https://github.com/\(repository)/releases/latest/download/encore-update.json")
    }

    public static func fetchLatest(repository: String, http: HTTPClient = HTTPClient()) async -> UpdateManifest? {
        guard let url = latestURL(repository: repository) else { return nil }
        return try? await http.get(url, as: UpdateManifest.self, timeout: 10)
    }
}
