import Foundation

/// The households an account manages besides its own, kept in Encore Cloud under that account so every
/// device signed in to it shows the same list: a sibling's household shared with you, and households
/// with no Stremio account (whose profiles and history travel inside the directory).
public struct HouseholdDirectoryDocument: Codable, Equatable, Sendable {
    public var households: [Entry]

    public struct Entry: Codable, Equatable, Sendable {
        /// `DirectoryKey`: "account:<Stremio user id>" or "local:<household id>".
        public var key: String
        public var name: String
        public var symbol: String
        public var updatedAt: Date
        public var deleted: Bool
        /// The Stremio session of a household signed in to its own account.
        public var account: Account?
        /// Everything a household without a Stremio account has (profiles, history, settings).
        public var document: HouseholdDocument?

        public struct Account: Codable, Equatable, Sendable {
            public var userID: String
            public var email: String?
            public var authKey: String
        }

        public init(key: String, name: String, symbol: String, updatedAt: Date, deleted: Bool = false,
                    account: Account? = nil, document: HouseholdDocument? = nil) {
            self.key = key; self.name = name; self.symbol = symbol; self.updatedAt = updatedAt
            self.deleted = deleted; self.account = account; self.document = document
        }
    }

    public init(households: [Entry] = []) { self.households = households }

    func encoded() throws -> Data { try HouseholdDocument.encoder.encode(self) }
    static func decode(_ data: Data) throws -> HouseholdDirectoryDocument {
        try HouseholdDocument.decoder.decode(HouseholdDirectoryDocument.self, from: data)
    }
    func normalized() -> HouseholdDirectoryDocument { (try? encoded()).flatMap { try? Self.decode($0) } ?? self }

    /// Per household, the newer entry wins (a removal is an entry too). The profiles and history inside
    /// a household without an account are merged field by field, like a synced household.
    public static func merge(local: HouseholdDirectoryDocument, remote: HouseholdDirectoryDocument) -> HouseholdDirectoryDocument {
        let local = local.normalized()
        var merged = remote.households
        for entry in local.households {
            guard let index = merged.firstIndex(where: { $0.key == entry.key }) else {
                merged.append(entry)
                continue
            }
            let theirs = merged[index]
            var winner = entry.updatedAt > theirs.updatedAt ? entry : theirs
            if !winner.deleted, let mine = entry.document, let other = theirs.document {
                winner.document = HouseholdDocument.merge(local: mine, remote: other)
            } else if !winner.deleted, winner.document == nil {
                winner.document = entry.document ?? theirs.document
            }
            if !winner.deleted, winner.account == nil { winner.account = entry.account ?? theirs.account }
            merged[index] = winner
        }
        return HouseholdDirectoryDocument(households: merged.sorted { $0.key < $1.key })
    }
}

/// Keeps this device's households and its home account's directory in step.
public struct DirectorySync: Sendable {
    public let client: CloudClient
    public init(client: CloudClient) { self.client = client }

    public struct Outcome: Equatable, Sendable {
        public var added: [Household]
        public var removed: [UUID]
        public var pushed: Bool
    }

    /// The household that owns the directory on this device: the one recorded, or else the earliest
    /// household signed in to its own account that was not shared with this person.
    public static func home(in directory: HouseholdDirectory) -> Household? {
        let households = directory.registry().households
        if let id = directory.syncState.homeID, let home = households.first(where: { $0.id == id }),
           HouseholdSession(scope: directory.scope(for: home)).isSignedIn {
            return home
        }
        let candidate = households
            .filter { household in
                let settings = directory.settings(for: household)
                return settings?.isSharedWithMe != true
                    && HouseholdSession(scope: directory.scope(for: household)).isSignedIn
            }
            .min { $0.createdAt < $1.createdAt }
        if let candidate { directory.updateSyncState { $0.homeID = candidate.id } }
        return candidate
    }

    /// - Parameter activeID: the open household; it is never removed from under the viewer.
    /// - Returns: nil when no household on this device is signed in (there is no account to sync with).
    public func sync(_ directory: HouseholdDirectory, activeID: UUID) async throws -> Outcome? {
        guard let home = Self.home(in: directory) else { return nil }
        let homeSession = HouseholdSession(scope: directory.scope(for: home))
        guard let authKey = homeSession.cloudAuthKey else { return nil }
        let homeUser = homeSession.settings.accountUserID

        var remote = try await client.fetchDirectory(authKey: authKey)
        for _ in 0..<4 {
            let local = Self.localDocument(directory, home: home, homeUser: homeUser)
            let merged = remote.map { HouseholdDirectoryDocument.merge(local: local, remote: $0.document) } ?? local.normalized()
            if let remote, merged == remote.document {
                let outcome = Self.apply(merged, to: directory, home: home, homeUser: homeUser, activeID: activeID)
                directory.updateSyncState { $0.version = remote.version }
                return Outcome(added: outcome.added, removed: outcome.removed, pushed: false)
            }
            switch try await client.putDirectory(merged, baseVersion: remote?.version ?? 0, authKey: authKey) {
            case let .saved(version):
                let outcome = Self.apply(merged, to: directory, home: home, homeUser: homeUser, activeID: activeID)
                directory.updateSyncState { $0.version = version }
                return Outcome(added: outcome.added, removed: outcome.removed, pushed: true)
            case let .conflict(newer):
                remote = newer
            }
        }
        throw CloudClient.CloudError.server(409)
    }

    /// This device's households (other than home), plus the ones it has removed.
    static func localDocument(_ directory: HouseholdDirectory, home: Household, homeUser: String?) -> HouseholdDirectoryDocument {
        var entries: [HouseholdDirectoryDocument.Entry] = []
        for household in directory.registry().households where household.id != home.id {
            let session = HouseholdSession(scope: directory.scope(for: household))
            let settings = session.settings
            if let user = settings.accountUserID, user == homeUser { continue }   // the home account itself
            let updatedAt = session.cloudState.nameUpdatedAt
            if let user = settings.accountUserID, let key = session.cloudAuthKey {
                entries.append(.init(key: DirectoryKey.account(user), name: household.name, symbol: household.symbol,
                                     updatedAt: updatedAt,
                                     account: .init(userID: user, email: settings.accountEmail ?? settings.ownerEmail, authKey: key)))
            } else if settings.accountUserID == nil {
                entries.append(.init(key: DirectoryKey.local(household.id), name: household.name, symbol: household.symbol,
                                     updatedAt: updatedAt,
                                     document: session.cloudDocument(name: household.name, symbol: household.symbol)))
            }
            // A household bound to an account but signed out stays on this device only.
        }
        for (key, date) in directory.syncState.deleted where !entries.contains(where: { $0.key == key }) {
            entries.append(.init(key: key, name: "", symbol: "house.fill", updatedAt: date, deleted: true))
        }
        return HouseholdDirectoryDocument(households: entries)
    }

    /// Make this device's households match the merged directory.
    static func apply(_ document: HouseholdDirectoryDocument, to directory: HouseholdDirectory, home: Household,
                      homeUser: String?, activeID: UUID) -> (added: [Household], removed: [UUID]) {
        var added: [Household] = []
        var removed: [UUID] = []
        let households = directory.registry().households
        for entry in document.households {
            if let account = entry.account {
                guard account.userID != homeUser else { continue }
                let existing = directory.household(boundTo: account.userID)
                if entry.deleted {
                    if let existing, existing.id != activeID, existing.id != home.id {
                        directory.delete(existing.id, remember: false)
                        removed.append(existing.id)
                    }
                    continue
                }
                guard existing == nil else { continue }
                let household = directory.add(name: entry.name, symbol: entry.symbol)
                let session = HouseholdSession(scope: directory.scope(for: household))
                try? session.store(.init(authKey: account.authKey, user: .init(id: account.userID, email: account.email ?? "")),
                                   sharedWithMe: true)
                added.append(household)
            } else if entry.key.hasPrefix("local:"), let id = UUID(uuidString: String(entry.key.dropFirst(6))) {
                let existing = households.first { $0.id == id }
                if entry.deleted {
                    if let existing, existing.id != activeID, existing.id != home.id {
                        directory.delete(existing.id, remember: false)
                        removed.append(existing.id)
                    }
                    continue
                }
                let household = existing ?? directory.add(name: entry.name, symbol: entry.symbol, id: id)
                if existing == nil { added.append(household) }
                if let existing, existing.name != entry.name || existing.symbol != entry.symbol {
                    directory.rename(existing.id, to: entry.name, symbol: entry.symbol)
                }
                if let doc = entry.document {
                    let session = HouseholdSession(scope: directory.scope(for: household))
                    session.apply(doc, version: session.cloudState.version)
                }
            }
        }
        // Removals that have now been shared need not be remembered forever: the merged entry carries them.
        directory.updateSyncState { state in
            state.deleted = state.deleted.filter { key, _ in document.households.contains { $0.key == key && $0.deleted } }
        }
        return (added, removed)
    }
}
