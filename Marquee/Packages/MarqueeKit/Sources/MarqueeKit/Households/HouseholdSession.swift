import Foundation

/// Household-level settings that are not secrets.
public struct HouseholdSettings: Codable, Hashable, Sendable {
    public var accountEmail: String?
    public var addons: [Addon]
    /// A Stremio streaming server (Stremio Service on a Mac/PC/NAS). Only torrents need it.
    public var streamingServer: URL?
    public var preferences: StreamPreferences

    public init(accountEmail: String? = nil, addons: [Addon] = DefaultAddons.all,
                streamingServer: URL? = nil, preferences: StreamPreferences = StreamPreferences()) {
        self.accountEmail = accountEmail; self.addons = addons
        self.streamingServer = streamingServer; self.preferences = preferences
    }
}

/// One entry in Continue Watching.
public struct ContinueItem: Hashable, Identifiable, Sendable {
    public var item: StremioLibraryItem
    public var id: String { item.id }
}

/// Everything one household does: its Stremio account, add-ons, profiles, and each profile's library.
///
/// The owner profile's library is the Stremio account library (cached here, pushed on change), so it
/// stays in step with Stremio on every other device. Other profiles keep a library of the same shape
/// inside the household. One model, one code path for Continue Watching, My List, and resume.
///
/// Thread-safety: a lock guards the in-memory state; network work happens outside it.
public final class HouseholdSession: @unchecked Sendable {
    public let scope: HouseholdScope
    public let addonService: AddonService
    public let api: StremioAPI

    private let settingsFile: JSONFile<HouseholdSettings>
    private let roster: ProfileRoster
    private let lock = NSLock()
    private var _settings: HouseholdSettings
    private var libraries: [UUID: [String: StremioLibraryItem]] = [:]
    private var dirtyAccountItems: [String: StremioLibraryItem] = [:]

    private static let authKeyName = "stremio.authKey"

    public init(scope: HouseholdScope, addonService: AddonService = AddonService(), api: StremioAPI = StremioAPI()) {
        self.scope = scope
        self.addonService = addonService
        self.api = api
        settingsFile = scope.file("settings.json")
        roster = ProfileRoster(scope: scope)
        _settings = settingsFile.load() ?? HouseholdSettings()
    }

    // MARK: State

    public var settings: HouseholdSettings {
        lock.lock(); defer { lock.unlock() }
        return _settings
    }

    public func updateSettings(_ change: (inout HouseholdSettings) -> Void) {
        lock.lock()
        change(&_settings)
        let snapshot = _settings
        lock.unlock()
        try? settingsFile.save(snapshot)
    }

    public var isSignedIn: Bool { authKey != nil }
    var authKey: String? { scope.secrets.string(Self.authKeyName) }

    public func profiles() -> [Profile] { roster.load() }
    public func saveProfiles(_ profiles: [Profile]) {
        // The owner can be renamed but never removed.
        guard profiles.contains(where: \.isOwner) else { return }
        roster.save(profiles)
    }

    // MARK: Account

    public func signIn(email: String, password: String) async throws {
        let session = try await api.login(email: email, password: password)
        scope.secrets.set(session.authKey, for: Self.authKeyName)
        updateSettings { $0.accountEmail = session.user.email }
        try await refreshFromAccount()
    }

    public func signOut() async {
        if let key = authKey { await api.logout(authKey: key) }
        scope.secrets.set(nil, for: Self.authKeyName)
        updateSettings {
            $0.accountEmail = nil
            $0.addons = DefaultAddons.all
        }
        let owner = roster.load().first(where: \.isOwner)
        lock.withLock {
            dirtyAccountItems = [:]
            if let owner { libraries[owner.id] = [:] }
        }
        if let owner = roster.load().first(where: \.isOwner) { libraryFile(owner).remove() }
    }

    /// Pull the account's add-ons and library. A failure leaves the cached state untouched.
    public func refreshFromAccount() async throws {
        guard let key = authKey else { return }
        async let addons = api.addonCollection(authKey: key)
        async let items = api.library(authKey: key)
        let (remoteAddons, remoteItems) = try await (addons, items)
        if !remoteAddons.isEmpty { updateSettings { $0.addons = remoteAddons } }
        guard let owner = roster.load().first(where: \.isOwner) else { return }
        let merged = lock.withLock {
            var merged = libraries[owner.id] ?? loadLibrary(owner)
            for remote in remoteItems {
                // Last writer wins per item, so a local edit not yet pushed is not clobbered by an older copy.
                if let local = merged[remote.id], local.modified > remote.modified { continue }
                merged[remote.id] = remote
            }
            libraries[owner.id] = merged
            return merged
        }
        try? libraryFile(owner).save(Array(merged.values))
    }

    /// Push owner library edits made since the last push. Safe to call often; cheap when nothing changed.
    public func pushPendingLibraryChanges() async {
        guard let key = authKey else { return }
        let pending = lock.withLock {
            let pending = Array(dirtyAccountItems.values)
            dirtyAccountItems = [:]
            return pending
        }
        do {
            try await api.putLibrary(authKey: key, items: pending)
        } catch {
            lock.withLock {
                for item in pending where dirtyAccountItems[item.id] == nil { dirtyAccountItems[item.id] = item }
            }
        }
    }

    // MARK: Add-ons

    public func installAddon(from raw: String) async throws -> Addon {
        let addon = try await addonService.fetchAddon(from: raw)
        updateSettings { s in
            s.addons.removeAll { $0.transportURL == addon.transportURL }
            s.addons.append(addon)
        }
        await pushAddons()
        return addon
    }

    public func removeAddon(_ addon: Addon) async {
        updateSettings { $0.addons.removeAll { $0.id == addon.id } }
        await pushAddons()
    }

    public func moveAddons(fromOffsets source: IndexSet, toOffset destination: Int) async {
        updateSettings { s in
            let moving = source.sorted().map { s.addons[$0] }
            for index in source.sorted(by: >) { s.addons.remove(at: index) }
            let adjusted = destination - source.filter { $0 < destination }.count
            s.addons.insert(contentsOf: moving, at: min(max(0, adjusted), s.addons.count))
        }
        await pushAddons()
    }

    private func pushAddons() async {
        guard let key = authKey else { return }
        try? await api.setAddonCollection(authKey: key, addons: settings.addons)
    }

    // MARK: Library

    private func libraryFile(_ profile: Profile) -> JSONFile<[StremioLibraryItem]> {
        scope.file("library-\(profile.isOwner ? "account" : profile.id.uuidString).json")
    }

    /// Caller holds the lock.
    private func loadLibrary(_ profile: Profile) -> [String: StremioLibraryItem] {
        let items = libraryFile(profile).load() ?? []
        return Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { $0.modified > $1.modified ? $0 : $1 })
    }

    public func library(for profile: Profile) -> [StremioLibraryItem] {
        lock.lock(); defer { lock.unlock() }
        let items = libraries[profile.id] ?? loadLibrary(profile)
        libraries[profile.id] = items
        return Array(items.values)
    }

    public func item(_ id: String, for profile: Profile) -> StremioLibraryItem? {
        library(for: profile).first { $0.id == id }
    }

    public func continueWatching(for profile: Profile) -> [ContinueItem] {
        library(for: profile)
            .filter(\.isInProgress)
            .sorted { ($0.state.lastWatched ?? .distantPast) > ($1.state.lastWatched ?? .distantPast) }
            .map(ContinueItem.init)
    }

    public func myList(for profile: Profile) -> [StremioLibraryItem] {
        library(for: profile).filter(\.isInLibrary).sorted { $0.modified > $1.modified }
    }

    public func setInLibrary(_ meta: MetaPreview, _ inLibrary: Bool, for profile: Profile) {
        mutate(meta, profile) { item in
            item.temp = !inLibrary
            item.removed = !inLibrary && !item.isInProgress
        }
    }

    public func recordProgress(_ meta: MetaPreview, videoID: String?, position: TimeInterval,
                               duration: TimeInterval, for profile: Profile) {
        mutate(meta, profile) { $0.recordProgress(videoID: videoID, position: position, duration: duration) }
    }

    /// Remove from Continue Watching without touching My List.
    public func dismissFromContinueWatching(_ id: String, for profile: Profile) {
        guard let existing = item(id, for: profile) else { return }
        mutate(MetaPreview(id: existing.id, type: existing.type, name: existing.name, poster: existing.poster), profile) {
            $0.state.timeOffset = 0
            if $0.temp { $0.removed = true }
        }
    }

    private func mutate(_ meta: MetaPreview, _ profile: Profile, _ change: (inout StremioLibraryItem) -> Void) {
        lock.lock()
        var items = libraries[profile.id] ?? loadLibrary(profile)
        var item = items[meta.id] ?? StremioLibraryItem(meta: meta)
        if item.name.isEmpty { item.name = meta.name }
        if item.poster == nil { item.poster = meta.poster }
        change(&item)
        item.modified = Date()
        items[meta.id] = item
        libraries[profile.id] = items
        if profile.isOwner && authKey != nil { dirtyAccountItems[item.id] = item }
        let snapshot = Array(items.values)
        lock.unlock()
        try? libraryFile(profile).save(snapshot)
    }

    // MARK: Streams

    public func rankedStreams(type: String, id: String,
                              onPartial: (@Sendable ([RankedStream]) async -> Void)? = nil) async -> [RankedStream] {
        let s = settings
        let torrentsPlayable = s.streamingServer != nil
        let groups = await addonService.streams(type: type, id: id, in: s.addons) { partial in
            await onPartial?(StreamRanking.rank(partial, preferences: s.preferences, torrentsPlayable: torrentsPlayable))
        }
        return StreamRanking.rank(groups, preferences: s.preferences, torrentsPlayable: torrentsPlayable)
    }

    public func playbackSource(for ranked: RankedStream, title: String) -> PlaybackSource? {
        PlaybackSource.resolve(ranked.stream, streamingServer: settings.streamingServer, title: title)
    }
}

/// The add-ons a fresh household starts with: Cinemeta for the catalog and metadata. The manifest is
/// embedded so Home renders on first launch before any network round trip; it is refreshed on sign-in.
public enum DefaultAddons {
    public static let cinemetaURL = URL(string: "https://v3-cinemeta.strem.io/manifest.json")!

    public static var all: [Addon] { [cinemeta] }

    public static let cinemeta = Addon(
        transportURL: cinemetaURL,
        manifest: AddonManifest(
            id: "com.linvo.cinemeta", version: "3.0.0", name: "Cinemeta",
            description: "The official add-on for movie and series catalogs",
            types: ["movie", "series"],
            resources: [.init(name: "catalog"),
                        .init(name: "meta", types: ["movie", "series"], idPrefixes: ["tt"]),
                        .init(name: "addon_catalog")],
            catalogs: [
                .init(type: "movie", id: "top", name: "Popular",
                      extra: [.init(name: "genre", isRequired: false, options: nil),
                              .init(name: "search", isRequired: false, options: nil),
                              .init(name: "skip", isRequired: false, options: nil)]),
                .init(type: "series", id: "top", name: "Popular",
                      extra: [.init(name: "genre", isRequired: false, options: nil),
                              .init(name: "search", isRequired: false, options: nil),
                              .init(name: "skip", isRequired: false, options: nil)]),
                .init(type: "movie", id: "imdbRating", name: "Featured",
                      extra: [.init(name: "genre", isRequired: false, options: nil),
                              .init(name: "skip", isRequired: false, options: nil)]),
                .init(type: "series", id: "imdbRating", name: "Featured",
                      extra: [.init(name: "genre", isRequired: false, options: nil),
                              .init(name: "skip", isRequired: false, options: nil)]),
            ],
            idPrefixes: ["tt"]),
        isProtected: true)
}
