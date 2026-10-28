import Foundation

/// Household-level settings that are not secrets.
public struct HouseholdSettings: Codable, Hashable, Sendable {
    public var accountEmail: String?
    /// The Stremio user this household belongs to. Set on first sign-in and kept after sign-out, so the
    /// household stays that person's: signing in with a different account opens (or creates) that
    /// account's own household instead of mixing the two.
    public var accountUserID: String?
    /// The email of that account, kept after sign-out so the household can say whose it is.
    public var ownerEmail: String?
    public var addons: [Addon]
    /// A Stremio streaming server (Stremio Service on a Mac/PC/NAS). Only torrents need it.
    public var streamingServer: URL?
    public var preferences: StreamPreferences
    /// Someone else's household, managed from here (added with a share code or from the account's
    /// directory). Never chosen as this device's home household.
    public var isSharedWithMe: Bool?

    public init(accountEmail: String? = nil, accountUserID: String? = nil, addons: [Addon] = DefaultAddons.all,
                streamingServer: URL? = nil, preferences: StreamPreferences = StreamPreferences()) {
        self.accountEmail = accountEmail; self.accountUserID = accountUserID; self.addons = addons
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
        let before = _settings
        change(&_settings)
        let snapshot = _settings
        lock.unlock()
        try? settingsFile.save(snapshot)
        if before.streamingServer != snapshot.streamingServer || before.preferences != snapshot.preferences {
            updateCloudState { $0.settingsUpdatedAt = Date() }
        }
    }

    public var isSignedIn: Bool { authKey != nil }
    var authKey: String? { scope.secrets.string(Self.authKeyName) }

    public func profiles() -> [Profile] { roster.load() }

    /// Save the roster, stamping edited profiles and remembering deleted ones so Encore Cloud carries
    /// both changes to the household's other devices.
    public func saveProfiles(_ profiles: [Profile], now: Date = Date()) {
        // The owner can be renamed but never removed.
        guard profiles.contains(where: \.isOwner) else { return }
        let before = Dictionary(roster.load().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var stamped = profiles
        for index in stamped.indices {
            if let old = before[stamped[index].id], old.sameContent(as: stamped[index]) {
                stamped[index].updatedAt = old.updatedAt
            } else {
                stamped[index].updatedAt = now
            }
        }
        roster.save(stamped)
        let removed = Set(before.keys).subtracting(stamped.map(\.id))
        guard !removed.isEmpty else { return }
        updateCloudState { state in
            for id in removed { state.deletedProfiles[id.uuidString] = now }
        }
        lock.withLock { for id in removed { libraries[id] = nil } }
        for id in removed { scope.file("library-\(id.uuidString).json", as: [StremioLibraryItem].self).remove() }
    }

    // MARK: Account

    public enum BindingError: Error, Equatable, Sendable {
        /// This household belongs to another Stremio account.
        case belongsToAnotherAccount(email: String?)
    }

    public func signIn(email: String, password: String) async throws {
        try await adopt(try await api.login(email: email, password: password))
    }

    /// Whether `session` may sign in here: an unclaimed household, or the account it already belongs to.
    public func accepts(_ session: StremioAPI.Session) -> Bool {
        let owner = settings.accountUserID
        return owner == nil || owner == session.user.id
    }

    /// Store a signed-in session in this household and claim the household for that account.
    public func adopt(_ session: StremioAPI.Session) async throws {
        try store(session)
        try await refreshFromAccount()
    }

    /// `adopt` without the network: the account's add-ons and library arrive on the next refresh.
    public func store(_ session: StremioAPI.Session, sharedWithMe: Bool? = nil) throws {
        guard accepts(session) else { throw BindingError.belongsToAnotherAccount(email: settings.ownerEmail) }
        scope.secrets.set(session.authKey, for: Self.authKeyName)
        updateSettings {
            $0.accountEmail = session.user.email
            $0.accountUserID = session.user.id
            $0.ownerEmail = session.user.email
            if let sharedWithMe { $0.isSharedWithMe = sharedWithMe }
        }
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

    /// Release a signed-out household from its account so a different account can claim it.
    public func forgetAccountBinding() {
        guard !isSignedIn else { return }
        updateSettings { $0.accountUserID = nil; $0.ownerEmail = nil }
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

    /// - Parameter upNext: the episode after this one, if any. Finishing an episode then keeps the show in
    ///   Continue Watching, pointing at that next episode, instead of dropping it (a finished episode has no
    ///   position left to resume, which used to empty Continue Watching of every show watched to the end).
    public func recordProgress(_ meta: MetaPreview, videoID: String?, position: TimeInterval,
                               duration: TimeInterval, upNext: String? = nil, for profile: Profile) {
        mutate(meta, profile) { $0.recordProgress(videoID: videoID, position: position, duration: duration) }
        // Finishing something marks it watched.
        guard duration > 0, position / duration >= 0.92 else { return }
        setWatched([videoID ?? meta.id], true, for: profile)
        if let upNext, upNext != videoID {
            mutate(meta, profile) { $0.pointToNextEpisode(upNext) }
        }
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

    // MARK: Encore Cloud

    /// What this device knows about the household's copy in Encore Cloud.
    public struct CloudState: Codable, Equatable, Sendable {
        /// The cloud version this device last merged with (0: never synced).
        public var version: Int = 0
        public var lastSynced: Date?
        public var deletedProfiles: [String: Date] = [:]
        public var settingsUpdatedAt: Date = .distantPast
        public var nameUpdatedAt: Date = .distantPast
        public init() {}
    }

    private var cloudFile: JSONFile<CloudState> { scope.file("cloud.json") }

    public var cloudState: CloudState { lock.withLock { cloudFile.load() ?? CloudState() } }

    public func updateCloudState(_ change: (inout CloudState) -> Void) {
        lock.withLock {
            var state = cloudFile.load() ?? CloudState()
            change(&state)
            try? cloudFile.save(state)
        }
    }

    /// The account key Encore Cloud authenticates with (the household's Stremio session).
    public var cloudAuthKey: String? { authKey }

    /// This device's view of the household, as a cloud document.
    public func cloudDocument(name: String, symbol: String) -> HouseholdDocument {
        let state = cloudState
        let s = settings
        let roster = profiles()
        var libraries: [String: [StremioLibraryItem]] = [:]
        for profile in roster where !profile.isOwner {
            libraries[profile.id.uuidString] = library(for: profile).sorted { $0.id < $1.id }
        }
        var watched: [String: [String: WatchMark]] = [:]
        for profile in roster {
            let marks = watchMarks(for: profile)
            if !marks.isEmpty { watched[HouseholdDocument.watchedKey(profile)] = marks }
        }
        var document = HouseholdDocument(
            name: name, symbol: symbol, nameUpdatedAt: state.nameUpdatedAt, profiles: roster,
            deletedProfiles: state.deletedProfiles, libraries: libraries,
            settings: .init(streamingServer: s.streamingServer, preferences: s.preferences, updatedAt: state.settingsUpdatedAt))
        document.watched = watched.isEmpty ? nil : watched
        return document
    }

    /// Make this device match a merged cloud document. The local owner keeps its id (its library is the
    /// Stremio account's); everything else is taken from the document.
    public func apply(_ document: HouseholdDocument, version: Int) {
        let localOwner = roster.load().first(where: \.isOwner)
        let profiles = document.profiles.map { profile -> Profile in
            guard profile.isOwner, let localOwner else { return profile }
            var owner = profile
            owner.id = localOwner.id
            return owner
        }
        if profiles.contains(where: \.isOwner) { roster.save(profiles) }

        let previous = Set(lock.withLock { Array(libraries.keys) })
        for profile in profiles where !profile.isOwner {
            let items = document.libraries[profile.id.uuidString] ?? []
            lock.withLock { libraries[profile.id] = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }
            try? libraryFile(profile).save(items)
        }
        let living = Set(profiles.map(\.id))
        for id in previous.subtracting(living) where id != localOwner?.id {
            lock.withLock { libraries[id] = nil }
            scope.file("library-\(id.uuidString).json", as: [StremioLibraryItem].self).remove()
        }

        for profile in profiles {
            let marks = document.watched?[HouseholdDocument.watchedKey(profile)] ?? [:]
            lock.withLock { try? watchedFile(profile).save(marks) }
        }

        lock.lock()
        _settings.streamingServer = document.settings.streamingServer
        _settings.preferences = document.settings.preferences
        let snapshot = _settings
        lock.unlock()
        try? settingsFile.save(snapshot)

        updateCloudState { state in
            state.version = version
            state.lastSynced = Date()
            state.deletedProfiles = document.deletedProfiles
            state.settingsUpdatedAt = document.settings.updatedAt
            state.nameUpdatedAt = document.nameUpdatedAt
        }
    }

    // MARK: Watched

    /// One profile's "watched" marks, by video id (an episode id, or a movie's id). Unmarking is a mark
    /// too (watched: false), so the newest decision wins when devices sync.
    public struct WatchMark: Codable, Hashable, Sendable {
        public var watched: Bool
        public var at: Date
        public init(watched: Bool, at: Date) { self.watched = watched; self.at = at }
    }

    private func watchedFile(_ profile: Profile) -> JSONFile<[String: WatchMark]> {
        scope.file("watched-\(profile.isOwner ? "account" : profile.id.uuidString).json")
    }

    public func watchMarks(for profile: Profile) -> [String: WatchMark] {
        lock.withLock { watchedFile(profile).load() ?? [:] }
    }

    public func isWatched(_ videoID: String, for profile: Profile) -> Bool {
        watchMarks(for: profile)[videoID]?.watched == true
    }

    public func setWatched(_ videoIDs: [String], _ watched: Bool, for profile: Profile, now: Date = Date()) {
        guard !videoIDs.isEmpty else { return }
        lock.withLock {
            var marks = watchedFile(profile).load() ?? [:]
            for id in videoIDs { marks[id] = WatchMark(watched: watched, at: now) }
            try? watchedFile(profile).save(marks)
        }
    }

    /// Mark a title (or one of its episodes) watched or unwatched. Marking the video the viewer is in the
    /// middle of also finishes it in the library, so it leaves Continue Watching, as on Stremio.
    public func markWatched(_ meta: MetaPreview, videoID: String?, watched: Bool, for profile: Profile) {
        setWatched([videoID ?? meta.id], watched, for: profile)
        guard let item = item(meta.id, for: profile), item.state.videoID == videoID || (videoID == nil && item.state.videoID == nil) || videoID == nil else { return }
        mutate(meta, profile) { item in
            item.state.timeOffset = 0
            if watched {
                item.state.flaggedWatched = 1
                item.state.timesWatched += 1
                item.state.lastWatched = Date()
            } else {
                item.state.flaggedWatched = 0
            }
        }
    }

    // MARK: Streams

    public func rankedStreams(type: String, id: String, limits: NetworkLimits? = nil,
                              onPartial: (@Sendable ([RankedStream]) async -> Void)? = nil) async -> [RankedStream] {
        let s = settings
        let torrentsPlayable = s.streamingServer != nil
        let groups = await addonService.streams(type: type, id: id, in: s.addons) { partial in
            await onPartial?(StreamRanking.rank(partial, preferences: s.preferences, torrentsPlayable: torrentsPlayable, limits: limits))
        }
        return StreamRanking.rank(groups, preferences: s.preferences, torrentsPlayable: torrentsPlayable, limits: limits)
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
