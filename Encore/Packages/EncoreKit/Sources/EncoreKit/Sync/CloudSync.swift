import Foundation

/// One sync pass between a household on this device and its copy in Encore Cloud:
/// pull, merge (newest edit wins per field), apply locally, and push if the merge changed anything.
/// A concurrent writer on another device makes the push fail with the newer copy; the pass merges
/// that and tries again, so no edit is ever overwritten.
public struct CloudSync: Sendable {
    public let client: CloudClient
    public init(client: CloudClient) { self.client = client }

    public struct Outcome: Equatable, Sendable {
        /// The household's name and icon after merging (another device may have renamed it).
        public var name: String
        public var symbol: String
        public var pushed: Bool
        public var version: Int
    }

    /// - Returns: nil when the household is not signed in to Stremio (there is nobody to sync as).
    public func sync(_ session: HouseholdSession, name: String, symbol: String) async throws -> Outcome? {
        guard let authKey = session.cloudAuthKey else { return nil }
        var remote = try await client.fetch(authKey: authKey)
        for _ in 0..<4 {
            let local = session.cloudDocument(name: name, symbol: symbol)
            let merged = remote.map { HouseholdDocument.merge(local: local, remote: $0.document) } ?? local.normalized()
            let baseVersion = remote?.version ?? 0
            if let remote, merged == remote.document {
                session.apply(merged, version: remote.version)
                return Outcome(name: merged.name, symbol: merged.symbol, pushed: false, version: remote.version)
            }
            switch try await client.put(merged, baseVersion: baseVersion, authKey: authKey) {
            case let .saved(version):
                session.apply(merged, version: version)
                return Outcome(name: merged.name, symbol: merged.symbol, pushed: true, version: version)
            case let .conflict(newer):
                remote = newer
            }
        }
        throw CloudClient.CloudError.server(409)
    }
}
