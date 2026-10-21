import Foundation

/// A household: one person's (or one family's) accounts and everything that belongs to them. Each
/// household is a separate directory plus a separate secret namespace, so nothing about one household
/// (sign-ins, add-ons, profiles, watch history, preferences) is visible to another. Switching is just
/// opening a different directory; there is no shared state to leak.
public struct Household: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var symbol: String
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, symbol: String = "house.fill", createdAt: Date = Date()) {
        self.id = id; self.name = name; self.symbol = symbol; self.createdAt = createdAt
    }
}

/// The list of households on this device and which one is open.
public final class HouseholdDirectory: @unchecked Sendable {
    public struct Registry: Codable, Sendable {
        public var households: [Household]
        public var activeID: UUID
    }

    public let root: URL
    private let registryFile: JSONFile<Registry>
    private let makeSecrets: @Sendable (UUID, URL) -> SecretStore
    private let lock = NSLock()

    /// - Parameter makeSecrets: builds the secret store for a household (Keychain on iOS/tvOS, a file on
    ///   macOS and in tests). Defaults to the platform choice.
    public init(root: URL, makeSecrets: (@Sendable (UUID, URL) -> SecretStore)? = nil) {
        self.root = root
        self.registryFile = JSONFile(root.appendingPathComponent("households.json"))
        self.makeSecrets = makeSecrets ?? { HouseholdDirectory.platformSecrets(id: $0, directory: $1) }
    }

    public static func platformSecrets(id: UUID, directory: URL) -> SecretStore {
        #if canImport(Security) && !os(macOS)
        return KeychainSecretStore(service: "encore.household." + id.uuidString,
                                   fallback: FileSecretStore(url: directory.appendingPathComponent("secrets-fallback.json")))
        #else
        return FileSecretStore(url: directory.appendingPathComponent("secrets.json"))
        #endif
    }

    /// The registry, created with one household on first launch.
    public func registry() -> Registry {
        lock.lock(); defer { lock.unlock() }
        if let existing = registryFile.load(), !existing.households.isEmpty,
           existing.households.contains(where: { $0.id == existing.activeID }) {
            return existing
        }
        let first = Household(name: "Home")
        let registry = Registry(households: [first], activeID: first.id)
        try? registryFile.save(registry)
        return registry
    }

    public func directory(for id: UUID) -> URL {
        root.appendingPathComponent("households", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func scope(for household: Household) -> HouseholdScope {
        let dir = directory(for: household.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return HouseholdScope(household: household, directory: dir, secrets: makeSecrets(household.id, dir))
    }

    /// The household on this device that belongs to a Stremio user, if any.
    public func household(boundTo userID: String) -> Household? {
        registry().households.first { household in
            JSONFile<HouseholdSettings>(directory(for: household.id).appendingPathComponent("settings.json"))
                .load()?.accountUserID == userID
        }
    }

    @discardableResult
    public func add(name: String, symbol: String = "house.fill", id: UUID = UUID()) -> Household {
        var reg = registry()
        if let existing = reg.households.first(where: { $0.id == id }) { return existing }
        let household = Household(id: id, name: name, symbol: symbol)
        reg.households.append(household)
        save(reg)
        return household
    }

    public func rename(_ id: UUID, to name: String, symbol: String? = nil) {
        var reg = registry()
        guard let index = reg.households.firstIndex(where: { $0.id == id }) else { return }
        reg.households[index].name = name
        if let symbol { reg.households[index].symbol = symbol }
        save(reg)
    }

    public func activate(_ id: UUID) {
        var reg = registry()
        guard reg.households.contains(where: { $0.id == id }) else { return }
        reg.activeID = id
        save(reg)
    }

    /// Delete a household that is not open, with all of its data and secrets. Unless `remember` is false,
    /// the deletion is remembered so Encore Cloud removes it from the account's other devices too.
    public func delete(_ id: UUID, remember: Bool = true, now: Date = Date()) {
        var reg = registry()
        guard id != reg.activeID, let household = reg.households.first(where: { $0.id == id }) else { return }
        if remember {
            let key = DirectoryKey.for(household, settings: settings(for: household))
            updateSyncState { $0.deleted[key] = now }
        }
        scope(for: household).secrets.removeAll()
        try? FileManager.default.removeItem(at: directory(for: id))
        reg.households.removeAll { $0.id == id }
        save(reg)
    }

    // MARK: Directory sync state (this device)

    /// What this device knows about its account's household directory in Encore Cloud.
    public struct SyncState: Codable, Equatable, Sendable {
        /// The household whose Stremio account holds the directory: the first one signed in here that
        /// was not shared with this person.
        public var homeID: UUID?
        public var version: Int = 0
        /// Directory key -> when its household was removed.
        public var deleted: [String: Date] = [:]
        public init() {}
    }

    private var syncFile: JSONFile<SyncState> { JSONFile(root.appendingPathComponent("directory-sync.json")) }

    public var syncState: SyncState { lock.withLock { syncFile.load() ?? SyncState() } }

    public func updateSyncState(_ change: (inout SyncState) -> Void) {
        lock.withLock {
            var state = syncFile.load() ?? SyncState()
            change(&state)
            try? syncFile.save(state)
        }
    }

    public func settings(for household: Household) -> HouseholdSettings? {
        JSONFile<HouseholdSettings>(directory(for: household.id).appendingPathComponent("settings.json")).load()
    }

    private func save(_ reg: Registry) {
        lock.lock(); defer { lock.unlock() }
        try? registryFile.save(reg)
    }
}

/// Everything a household owns, addressed through one value. Every store in the app is built from a
/// scope, which is what makes cross-household leaks structurally impossible rather than merely avoided.
public struct HouseholdScope: Sendable {
    public let household: Household
    public let directory: URL
    public let secrets: SecretStore

    public func file<T: Codable>(_ name: String, as: T.Type = T.self) -> JSONFile<T> {
        JSONFile(directory.appendingPathComponent(name))
    }
}

/// How a household is named in its account's directory: by its Stremio account when it has one (the same
/// household has a different local id on every device), otherwise by its id.
public enum DirectoryKey {
    public static func account(_ userID: String) -> String { "account:" + userID }
    public static func local(_ id: UUID) -> String { "local:" + id.uuidString }

    public static func `for`(_ household: Household, settings: HouseholdSettings?) -> String {
        if let user = settings?.accountUserID, !user.isEmpty { return account(user) }
        return local(household.id)
    }
}
