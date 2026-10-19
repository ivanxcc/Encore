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

    /// Which builds an install is offered. Stable: the latest release. Beta: also builds published for
    /// testing before they are promoted to everyone.
    public enum Channel: String, Codable, Sendable, CaseIterable {
        case stable, beta
    }

    /// The URL of the newest manifest on a channel for a GitHub repository ("owner/name").
    public static func latestURL(repository: String, channel: Channel = .stable) -> URL? {
        switch channel {
        case .stable: URL(string: "https://github.com/\(repository)/releases/latest/download/encore-update.json")
        case .beta: URL(string: "https://github.com/\(repository)/releases/download/beta-channel/encore-update.json")
        }
    }

    /// The newest build on the channel. Beta also looks at stable, so a beta install is never offered
    /// less than everyone else.
    public static func fetchLatest(repository: String, channel: Channel = .stable,
                                   http: HTTPClient = HTTPClient()) async -> UpdateManifest? {
        func fetch(_ channel: Channel) async -> UpdateManifest? {
            guard let url = latestURL(repository: repository, channel: channel) else { return nil }
            return try? await http.get(url, as: UpdateManifest.self, timeout: 10)
        }
        guard channel == .beta else { return await fetch(.stable) }
        async let beta = fetch(.beta)
        async let stable = fetch(.stable)
        return [await beta, await stable].compactMap { $0 }.max { $0.build < $1.build }
    }
}
