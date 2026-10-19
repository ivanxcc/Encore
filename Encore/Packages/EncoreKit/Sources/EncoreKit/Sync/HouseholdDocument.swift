import Foundation

/// A household as Encore Cloud stores it: everything Stremio itself doesn't already sync.
///
/// The owner profile's library IS the Stremio account library, so it syncs through Stremio. What the
/// cloud adds is the rest of the household: its name, its profiles (with PINs and kids flags), every
/// other profile's watch history and My List, and playback settings.
///
/// Merging is per field, newest edit wins, so two devices editing different things never lose either
/// edit, and the result is the same whichever device merges first.
public struct HouseholdDocument: Codable, Equatable, Sendable {
    public static let currentSchema = 1

    public var schema: Int
    public var name: String
    public var symbol: String
    public var nameUpdatedAt: Date
    public var profiles: [Profile]
    /// Profile id (uuidString) -> when it was deleted, so a deletion is not undone by a device that
    /// still has the profile. String keys keep the JSON a plain object.
    public var deletedProfiles: [String: Date]
    /// Non-owner profile id (uuidString) -> its library.
    public var libraries: [String: [StremioLibraryItem]]
    public var settings: SyncedSettings
    /// Each profile's watched marks: "owner" for the account's own profile (its id differs per
    /// device), else the profile id. Absent in documents from older builds.
    public var watched: [String: [String: HouseholdSession.WatchMark]]?

    static func watchedKey(_ profile: Profile) -> String { profile.isOwner ? "owner" : profile.id.uuidString }

    public struct SyncedSettings: Codable, Equatable, Sendable {
        public var streamingServer: URL?
        public var preferences: StreamPreferences
        public var updatedAt: Date

        public init(streamingServer: URL?, preferences: StreamPreferences, updatedAt: Date) {
            self.streamingServer = streamingServer; self.preferences = preferences; self.updatedAt = updatedAt
        }
    }

    public init(name: String, symbol: String, nameUpdatedAt: Date, profiles: [Profile],
                deletedProfiles: [String: Date] = [:], libraries: [String: [StremioLibraryItem]] = [:],
                settings: SyncedSettings) {
        schema = Self.currentSchema
        self.name = name; self.symbol = symbol; self.nameUpdatedAt = nameUpdatedAt
        self.profiles = profiles; self.deletedProfiles = deletedProfiles
        self.libraries = libraries; self.settings = settings
    }

    // MARK: Wire format

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func encoded() throws -> Data { try Self.encoder.encode(self) }

    static func decode(_ data: Data) throws -> HouseholdDocument { try decoder.decode(HouseholdDocument.self, from: data) }

    /// The document as it reads back from the wire (dates lose sub-second precision), so comparing a
    /// local document with a downloaded one only sees real differences.
    func normalized() -> HouseholdDocument {
        (try? encoded()).flatMap { try? Self.decode($0) } ?? self
    }

    // MARK: Merge

    /// Combine `local` (this device) with `remote` (the cloud). Newest edit wins per field and per item.
    public static func merge(local: HouseholdDocument, remote: HouseholdDocument) -> HouseholdDocument {
        let local = local.normalized()
        var merged = remote

        if local.nameUpdatedAt > remote.nameUpdatedAt {
            merged.name = local.name
            merged.symbol = local.symbol
            merged.nameUpdatedAt = local.nameUpdatedAt
        }
        if local.settings.updatedAt > remote.settings.updatedAt { merged.settings = local.settings }

        // Profiles created separately on two devices under the same name are the same person:
        // fold the local one into the cloud's so the household doesn't show "Will" twice.
        var localProfiles = local.profiles
        var localLibraries = local.libraries
        var localDeleted = local.deletedProfiles
        var localWatched = local.watched ?? [:]
        let remoteIDs = Set(remote.profiles.map(\.id))
        for index in localProfiles.indices where !remoteIDs.contains(localProfiles[index].id) {
            let profile = localProfiles[index]
            guard !profile.isOwner, remote.deletedProfiles[profile.id.uuidString] == nil,
                  let twin = remote.profiles.first(where: { candidate in
                      !candidate.isOwner && candidate.name.caseInsensitiveCompare(profile.name) == .orderedSame
                          && !localProfiles.contains(where: { $0.id == candidate.id })
                  }) else { continue }
            localProfiles[index].id = twin.id
            if let marks = localWatched.removeValue(forKey: profile.id.uuidString) { localWatched[twin.id.uuidString] = marks }
            if let items = localLibraries.removeValue(forKey: profile.id.uuidString) { localLibraries[twin.id.uuidString] = items }
            localDeleted.removeValue(forKey: profile.id.uuidString)
        }

        var deleted = remote.deletedProfiles
        for (id, date) in localDeleted where date > (deleted[id] ?? .distantPast) { deleted[id] = date }
        merged.deletedProfiles = deleted

        // The owner is matched by role, not id: each device created its own owner profile.
        var byID: [UUID: Profile] = [:]
        var order: [UUID] = []
        var owner: Profile? = remote.profiles.first(where: \.isOwner)
        for profile in remote.profiles where !profile.isOwner {
            byID[profile.id] = profile; order.append(profile.id)
        }
        for profile in localProfiles {
            if profile.isOwner {
                if owner == nil || profile.updatedAt > owner!.updatedAt {
                    owner = Profile(id: owner?.id ?? profile.id, name: profile.name, avatar: profile.avatar,
                                    colorIndex: profile.colorIndex, isOwner: true, isKids: profile.isKids,
                                    pinHash: profile.pinHash, updatedAt: profile.updatedAt)
                }
                continue
            }
            if let existing = byID[profile.id] {
                if profile.updatedAt > existing.updatedAt { byID[profile.id] = profile }
            } else {
                byID[profile.id] = profile; order.append(profile.id)
            }
        }
        merged.profiles = (owner.map { [$0] } ?? []) + order.compactMap { id in
            guard let profile = byID[id] else { return nil }
            if let gone = deleted[id.uuidString], gone >= profile.updatedAt { return nil }
            return profile
        }

        let living = Set(merged.profiles.filter { !$0.isOwner }.map(\.id.uuidString))
        var libraries: [String: [StremioLibraryItem]] = [:]
        for id in living {
            libraries[id] = mergeLibrary(localLibraries[id] ?? [], remote.libraries[id] ?? [])
        }
        merged.libraries = libraries

        // Watched marks: per profile and per video, the newer mark wins.
        var watched = remote.watched ?? [:]
        for (key, marks) in localWatched {
            var into = watched[key] ?? [:]
            for (id, mark) in marks where mark.at > (into[id]?.at ?? .distantPast) { into[id] = mark }
            watched[key] = into
        }
        let keep = Set(merged.profiles.map(HouseholdDocument.watchedKey))
        watched = watched.filter { keep.contains($0.key) }
        merged.watched = watched.isEmpty ? nil : watched
        merged.schema = max(local.schema, remote.schema)
        return merged
    }

    static func mergeLibrary(_ local: [StremioLibraryItem], _ remote: [StremioLibraryItem]) -> [StremioLibraryItem] {
        var items = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { $0.modified >= $1.modified ? $0 : $1 })
        for item in local where item.modified > (items[item.id]?.modified ?? .distantPast) { items[item.id] = item }
        return items.values.sorted { $0.id < $1.id }
    }
}
