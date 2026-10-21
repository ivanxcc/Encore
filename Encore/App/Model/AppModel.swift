import SwiftUI
import EncoreKit

/// The root of the app's state. It owns exactly one open household at a time; switching households
/// replaces the session object, and because every store is built from the household's scope, nothing
/// from the previous household survives the swap. No restart, no data shuffling.
@MainActor
final class AppModel: ObservableObject {
    let directory: HouseholdDirectory

    @Published private(set) var households: [Household] = []
    @Published private(set) var household: Household
    @Published private(set) var session: HouseholdSession
    @Published private(set) var profiles: [Profile] = []
    @Published var activeProfile: Profile?
    @Published private(set) var settings: HouseholdSettings
    /// Bumped whenever library or progress changes, so screens that read it refresh.
    @Published private(set) var libraryRevision = 0
    @Published var syncError: String?
    /// Encore Cloud, when this build was released with ENCORE_CLOUD_URL set.
    let cloud = CloudClient.configured()
    @Published private(set) var cloudStatus: CloudStatus = .off

    enum CloudStatus: Equatable {
        case off, syncing, synced(Date), failed(String)
    }

    init() {
        // Apple TV can only write to Caches; see StorageLocation.
        directory = HouseholdDirectory(root: StorageLocation.root)
        let registry = directory.registry()
        let household = registry.households.first { $0.id == registry.activeID } ?? registry.households[0]
        let session = HouseholdSession(scope: directory.scope(for: household))
        self.household = household
        self.session = session
        self.settings = session.settings
        self.households = registry.households
        reloadProfiles()
        // One profile and no PIN: go straight in. Otherwise the launch picker asks who is watching.
        if profiles.count == 1, !profiles[0].hasPin { activeProfile = profiles[0]; profileWasAutoPicked = true }
        if !StorageLocation.isWritable(directory.root) { storageFailure = true }
        Task { await refresh() }
    }

    /// This device refused to let Encore save its files: nothing (sign-in, profiles, households) would
    /// last, so it is reported instead of failing silently.
    private var storageFailure = false

    /// The only profile was chosen automatically (nobody was asked). If syncing then brings the
    /// household's other profiles, "Who's watching?" appears so they can be chosen.
    private var profileWasAutoPicked = false

    // MARK: Households

    func switchHousehold(to target: Household) {
        guard target.id != household.id else { return }
        Task { await session.pushPendingLibraryChanges() }   // the outgoing household's edits go to ITS account
        directory.activate(target.id)
        let next = HouseholdSession(scope: directory.scope(for: target))
        withAnimation(Theme.Motion.content) {
            household = target
            session = next
            settings = next.settings
            activeProfile = nil
            reloadProfiles()
            profileWasAutoPicked = false
            if profiles.count == 1, !profiles[0].hasPin { activeProfile = profiles[0]; profileWasAutoPicked = true }
            households = directory.registry().households
            libraryRevision += 1
        }
        Task { await refresh() }
    }

    func addHousehold(name: String, symbol: String) {
        directory.add(name: name.isEmpty ? "Household" : name, symbol: symbol)
        households = directory.registry().households
        syncSoon()
    }

    func renameHousehold(_ target: Household, name: String, symbol: String) {
        directory.rename(target.id, to: name, symbol: symbol)
        households = directory.registry().households
        if target.id == household.id, let updated = households.first(where: { $0.id == target.id }) {
            household = updated
            session.updateCloudState { $0.nameUpdatedAt = Date() }
            syncSoon()
        } else {
            HouseholdSession(scope: directory.scope(for: target)).updateCloudState { $0.nameUpdatedAt = Date() }
            syncSoon()
        }
    }

    func deleteHousehold(_ target: Household) {
        directory.delete(target.id)
        households = directory.registry().households
        syncSoon()
    }

    // MARK: Profiles

    func reloadProfiles() {
        profiles = session.profiles()
        if let active = activeProfile { activeProfile = profiles.first { $0.id == active.id } }
    }

    func saveProfile(_ profile: Profile) {
        var all = session.profiles()
        if let index = all.firstIndex(where: { $0.id == profile.id }) { all[index] = profile } else { all.append(profile) }
        session.saveProfiles(all)
        reloadProfiles()
        syncSoon()
    }

    func deleteProfile(_ profile: Profile) {
        guard !profile.isOwner else { return }
        session.saveProfiles(session.profiles().filter { $0.id != profile.id })
        if activeProfile?.id == profile.id { activeProfile = nil }
        reloadProfiles()
        syncSoon()
    }

    // MARK: Account and settings

    func refresh() async {
        do {
            try await session.refreshFromAccount()
            syncError = storageFailure ? "This device isn't letting Encore save anything, so sign-in and profiles won't stick. Reinstall Encore, then sign in again." : nil
        } catch {
            syncError = "Couldn't reach your Stremio account. Showing what's saved on this device."
        }
        settings = session.settings
        libraryRevision += 1
        await syncCloud()
    }

    enum SignInOutcome: Equatable {
        /// Signed in to the household that was open.
        case signedInHere
        /// The account already had a household on this device (or this one belongs to someone else), so
        /// Encore opened that account's own household instead of mixing two people's data.
        case switchedTo(Household)
    }

    /// Sign in, keeping every Stremio account in its own household:
    ///  - an account that already owns a household on this device opens it;
    ///  - this household, if unclaimed or already that account's, takes the session;
    ///  - otherwise a new household is created for the account and opened.
    @discardableResult
    func signIn(email: String, password: String) async throws -> SignInOutcome {
        try await signIn(with: try await session.api.login(email: email, password: password))
    }

    /// Sign in with a session from somewhere else (a phone approving this TV, a shared household).
    @discardableResult
    func signIn(with stremio: StremioAPI.Session, name: String? = nil) async throws -> SignInOutcome {
        var stremio = stremio
        if stremio.user.id.isEmpty {
            // Confirm the handed-over session and learn whose it is.
            stremio.user = try await session.api.user(authKey: stremio.authKey)
        }
        let owner = directory.household(boundTo: stremio.user.id)
        if owner == nil || owner?.id == household.id, session.accepts(stremio) {
            try await session.adopt(stremio)
            settings = session.settings
            libraryRevision += 1
            await syncCloud()
            return .signedInHere
        }
        let target = owner ?? directory.add(name: name ?? Self.householdName(for: stremio.user.email), symbol: "person.2.fill")
        let targetSession = HouseholdSession(scope: directory.scope(for: target))
        try await targetSession.adopt(stremio)
        switchHousehold(to: target)
        return .switchedTo(target)
    }

    // MARK: Encore Cloud

    private var syncTask: Task<Void, Never>?

    /// Merge this household with its cloud copy. Quiet: failures only show in Settings.
    func syncCloud() async {
        guard let cloud else { cloudStatus = .off; return }
        let session = self.session
        cloudStatus = .syncing
        do {
            // 1. The open household: its profiles, their history, its settings.
            if session.isSignedIn,
               let outcome = try await CloudSync(client: cloud).sync(session, name: household.name, symbol: household.symbol),
               session === self.session {
                let profilesBefore = profiles.count
                if outcome.name != household.name || outcome.symbol != household.symbol {
                    directory.rename(household.id, to: outcome.name, symbol: outcome.symbol)
                    households = directory.registry().households
                    if let updated = households.first(where: { $0.id == household.id }) { household = updated }
                }
                reloadProfiles()
                settings = session.settings
                libraryRevision += 1
                // A new device that went straight into its only profile now has the household's others:
                // ask who is watching, as the Apple TV app does after signing in.
                if profileWasAutoPicked, profilesBefore <= 1, profiles.count > 1 {
                    profileWasAutoPicked = false
                    withAnimation(Theme.Motion.content) { activeProfile = nil }
                }
            }
            // 2. The list of households: the ones your home account manages appear on every device.
            let directoryOutcome = try await DirectorySync(client: cloud).sync(directory, activeID: household.id)
            households = directory.registry().households
            if session === self.session, !session.isSignedIn {
                reloadProfiles()   // a household without an account may have just received its profiles
            }
            cloudStatus = session.isSignedIn || directoryOutcome != nil ? .synced(Date()) : .off
        } catch CloudClient.CloudError.signedOut {
            cloudStatus = .failed("Sign in to Stremio again to keep this household in sync.")
        } catch let CloudClient.CloudError.server(status) {
            cloudStatus = .failed("Encore Cloud had a problem (error \(status)). Changes are saved here and will sync later.")
        } catch let error as URLError {
            cloudStatus = .failed("Couldn't reach Encore Cloud (\(error.localizedDescription)). Changes are saved here and will sync later.")
        } catch {
            cloudStatus = .failed("Encore Cloud sync failed: \(error.localizedDescription)")
        }
    }

    /// The household whose account holds this device's list of households.
    var homeHousehold: Household? { DirectorySync.home(in: directory) }

    func isSharedWithMe(_ target: Household) -> Bool { directory.settings(for: target)?.isSharedWithMe == true }

    /// Settings › Households › "Make Home": the household whose account keeps the list of households.
    func makeHome(_ target: Household) {
        directory.updateSyncState { $0.homeID = target.id }
        objectWillChange.send()
        syncSoon()
    }

    /// Coalesce: a burst of edits becomes one sync a couple of seconds later.
    func syncSoon() {
        guard cloud != nil else { return }
        syncTask?.cancel()
        syncTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await syncCloud()
        }
    }

    enum CloudActionError: LocalizedError {
        case unavailable, signInFirst
        var errorDescription: String? {
            switch self {
            case .unavailable: "Encore Cloud isn't set up for this build."
            case .signInFirst: "Sign in to your Stremio account in this household first."
            }
        }
    }

    /// The household's owner creates a code; whoever enters it can manage this household too.
    func createShareCode() async throws -> CloudClient.Code {
        guard let cloud else { throw CloudActionError.unavailable }
        guard let key = session.cloudAuthKey else { throw CloudActionError.signInFirst }
        await syncCloud()
        return try await cloud.createShareCode(name: household.name, authKey: key)
    }

    /// Enter someone's share code: their household appears on this device, signed in as them, with
    /// their profiles. Your own household stays exactly as it was.
    func addSharedHousehold(code: String) async throws -> Household {
        guard let cloud else { throw CloudActionError.unavailable }
        guard let key = signedInKey() else { throw CloudActionError.signInFirst }
        let handoff = try await cloud.redeemShareCode(code, authKey: key)
        let target = directory.household(boundTo: handoff.ownerId)
            ?? directory.add(name: handoff.name ?? Self.householdName(for: handoff.email ?? "Shared"), symbol: "person.2.fill")
        let targetSession = HouseholdSession(scope: directory.scope(for: target))
        targetSession.forgetAccountBinding()
        try targetSession.store(handoff.session, sharedWithMe: true)
        try? await targetSession.refreshFromAccount()
        switchHousehold(to: target)
        return target
    }

    /// A phone or Mac approves the code an Apple TV is showing; the TV signs in as this household.
    func approveTV(code: String) async throws {
        guard let account = homeHousehold ?? signInAccounts.first else { throw CloudActionError.signInFirst }
        try await approveDevice(code: code, as: account)
    }

    /// Households on this device that can sign another device in (signed in to their own Stremio
    /// account), the home household first.
    var signInAccounts: [Household] {
        let home = homeHousehold?.id
        return households
            .filter { HouseholdSession(scope: directory.scope(for: $0)).isSignedIn }
            .sorted { ($0.id == home ? 0 : 1, $0.createdAt) < ($1.id == home ? 0 : 1, $1.createdAt) }
    }

    func accountEmail(of target: Household) -> String? {
        directory.settings(for: target)?.accountEmail
    }

    /// Approve a TV's (or Mac's) sign-in code as one of this device's accounts. Always an explicit
    /// choice, defaulting to the home household: approving with whichever household happened to be open
    /// signed TVs in to the wrong account.
    func approveDevice(code: String, as account: Household) async throws {
        guard let cloud else { throw CloudActionError.unavailable }
        let target = account.id == household.id ? session : HouseholdSession(scope: directory.scope(for: account))
        guard let key = target.cloudAuthKey else { throw CloudActionError.signInFirst }
        if account.id == household.id { await syncCloud() }   // the TV finds the latest profiles waiting
        try await cloud.approvePairing(code: code, authKey: key)
    }

    // MARK: Deep links

    struct PairRequest: Identifiable, Equatable { let code: String; var id: String { code } }

    /// A TV's QR code was scanned on this phone: ask which account to sign it in to.
    @Published var pendingPair: PairRequest?

    /// `encore://pair?code=ABCDEFGH` (from the QR code's landing page).
    func handle(_ url: URL) {
        guard url.scheme == "encore", url.host == "pair",
              let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value,
              code.count >= 8 else { return }
        pendingPair = PairRequest(code: code)
    }

    /// Any signed-in household's session, to authenticate requests that aren't about a household.
    private func signedInKey() -> String? {
        if let key = session.cloudAuthKey { return key }
        for other in households where other.id != household.id {
            if let key = HouseholdSession(scope: directory.scope(for: other)).cloudAuthKey { return key }
        }
        return nil
    }

    /// "sarah.chen@x.com" -> "Sarah".
    static func householdName(for email: String) -> String {
        let local = email.split(separator: "@").first.map(String.init) ?? email
        let first = local.split(whereSeparator: { ".-_+".contains($0) }).first.map(String.init) ?? local
        return first.prefix(1).uppercased() + first.dropFirst()
    }

    /// Settings > "Release from Account": lets a different account claim a signed-out household.
    func releaseHouseholdFromAccount() {
        session.forgetAccountBinding()
        settings = session.settings
    }

    func signOut() async {
        await session.signOut()
        settings = session.settings
        libraryRevision += 1
    }

    func updateSettings(_ change: (inout HouseholdSettings) -> Void) {
        session.updateSettings(change)
        settings = session.settings
        syncSoon()
    }

    func installAddon(_ raw: String) async throws {
        _ = try await session.installAddon(from: raw)
        settings = session.settings
    }

    func removeAddon(_ addon: Addon) async {
        await session.removeAddon(addon)
        settings = session.settings
    }

    func moveAddons(from source: IndexSet, to destination: Int) async {
        await session.moveAddons(fromOffsets: source, toOffset: destination)
        settings = session.settings
    }

    // MARK: Title extras (cast photos, original artwork)

    private var extrasCache: [String: TitleExtras] = [:]

    /// Cast with photos, the original-resolution backdrop and logo, the tagline, and the age rating, from
    /// Encore Cloud (TMDB). nil when the cloud has no TMDB key or the title is not an IMDb title.
    func extras(for meta: MetaPreview) async -> TitleExtras? {
        let imdb = meta.id.split(separator: ":").first.map(String.init) ?? meta.id
        if let hit = extrasCache[imdb] { return hit }
        guard let cloud, let extras = await cloud.titleExtras(imdbID: imdb, type: meta.type) else { return nil }
        extrasCache[imdb] = extras
        return extras
    }

    private var runtimeCache: [String: [Int: TimeInterval]] = [:]

    /// Each episode's exact length in a season (seconds by episode number), from Encore Cloud (TMDB).
    func episodeRuntimes(tmdbID: Int, season: Int) async -> [Int: TimeInterval] {
        let key = "\(tmdbID):\(season)"
        if let hit = runtimeCache[key] { return hit }
        guard let cloud else { return [:] }
        let runtimes = await cloud.episodeRuntimes(tmdbID: tmdbID, season: season)
        if !runtimes.isEmpty { runtimeCache[key] = runtimes }
        return runtimes
    }

    // MARK: Library

    func continueWatching() -> [ContinueItem] {
        guard let profile = activeProfile else { return [] }
        return session.continueWatching(for: profile)
    }

    func myList() -> [StremioLibraryItem] {
        guard let profile = activeProfile else { return [] }
        return session.myList(for: profile)
    }

    func libraryItem(_ id: String) -> StremioLibraryItem? {
        guard let profile = activeProfile else { return nil }
        return session.item(id, for: profile)
    }

    func setInList(_ meta: MetaPreview, _ inList: Bool) {
        guard let profile = activeProfile else { return }
        session.setInLibrary(meta, inList, for: profile)
        libraryRevision += 1
        pushSoon()
    }

    func isWatched(_ videoID: String) -> Bool {
        guard let profile = activeProfile else { return false }
        return session.isWatched(videoID, for: profile)
    }

    /// Mark a movie, or one episode of a show, watched or unwatched for the active profile.
    func setWatched(_ meta: MetaPreview, video: Video?, _ watched: Bool) {
        guard let profile = activeProfile else { return }
        session.markWatched(meta, videoID: video?.id, watched: watched, for: profile)
        libraryRevision += 1
        pushSoon()
        syncSoon()
    }

    func dismissContinueWatching(_ id: String) {
        guard let profile = activeProfile else { return }
        session.dismissFromContinueWatching(id, for: profile)
        libraryRevision += 1
        pushSoon()
    }

    func recordProgress(_ meta: MetaPreview, videoID: String?, position: TimeInterval, duration: TimeInterval) {
        guard let profile = activeProfile, duration > 0 else { return }
        session.recordProgress(meta, videoID: videoID, position: position, duration: duration, for: profile)
        libraryRevision += 1
    }

    private var pushTask: Task<Void, Never>?

    /// Coalesce account pushes: many quick edits become one request a few seconds later.
    func pushSoon() {
        pushTask?.cancel()
        let session = self.session
        pushTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await session.pushPendingLibraryChanges()
        }
        if activeProfile?.isOwner == false { syncSoon() }
    }

    func pushNow() {
        let session = self.session
        Task { await session.pushPendingLibraryChanges() }
        if cloud != nil, session.isSignedIn { Task { await syncCloud() } }
    }
}
