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

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = HouseholdDirectory(root: support.appendingPathComponent("Encore", isDirectory: true))
        let registry = directory.registry()
        let household = registry.households.first { $0.id == registry.activeID } ?? registry.households[0]
        let session = HouseholdSession(scope: directory.scope(for: household))
        self.household = household
        self.session = session
        self.settings = session.settings
        self.households = registry.households
        reloadProfiles()
        // One profile and no PIN: go straight in. Otherwise the launch picker asks who is watching.
        if profiles.count == 1, !profiles[0].hasPin { activeProfile = profiles[0] }
        Task { await refresh() }
    }

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
            if profiles.count == 1, !profiles[0].hasPin { activeProfile = profiles[0] }
            households = directory.registry().households
            libraryRevision += 1
        }
        Task { await refresh() }
    }

    func addHousehold(name: String, symbol: String) {
        directory.add(name: name.isEmpty ? "Household" : name, symbol: symbol)
        households = directory.registry().households
    }

    func renameHousehold(_ target: Household, name: String, symbol: String) {
        directory.rename(target.id, to: name, symbol: symbol)
        households = directory.registry().households
        if target.id == household.id, let updated = households.first(where: { $0.id == target.id }) { household = updated }
    }

    func deleteHousehold(_ target: Household) {
        directory.delete(target.id)
        households = directory.registry().households
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
    }

    func deleteProfile(_ profile: Profile) {
        guard !profile.isOwner else { return }
        session.saveProfiles(session.profiles().filter { $0.id != profile.id })
        if activeProfile?.id == profile.id { activeProfile = nil }
        reloadProfiles()
    }

    // MARK: Account and settings

    func refresh() async {
        do {
            try await session.refreshFromAccount()
            syncError = nil
        } catch {
            syncError = "Couldn't reach your Stremio account. Showing what's saved on this device."
        }
        settings = session.settings
        libraryRevision += 1
    }

    func signIn(email: String, password: String) async throws {
        try await session.signIn(email: email, password: password)
        settings = session.settings
        libraryRevision += 1
    }

    func signOut() async {
        await session.signOut()
        settings = session.settings
        libraryRevision += 1
    }

    func updateSettings(_ change: (inout HouseholdSettings) -> Void) {
        session.updateSettings(change)
        settings = session.settings
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
    }

    func pushNow() {
        let session = self.session
        Task { await session.pushPendingLibraryChanges() }
    }
}
