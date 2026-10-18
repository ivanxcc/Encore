import Foundation

/// A viewer inside a household. The owner profile's progress IS the signed-in Stremio account's library
/// (so it matches every other Stremio app); other profiles keep their own progress in the household.
public struct Profile: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// An SF Symbol or emoji shown in the avatar.
    public var avatar: String
    /// Index into the app's avatar color palette.
    public var colorIndex: Int
    public var isOwner: Bool
    public var isKids: Bool
    /// Salted SHA-256 of a 4-digit PIN; a parental gate, not a security boundary.
    public var pinHash: String?

    public init(id: UUID = UUID(), name: String, avatar: String = "person.fill", colorIndex: Int = 0,
                isOwner: Bool = false, isKids: Bool = false, pinHash: String? = nil) {
        self.id = id; self.name = name; self.avatar = avatar; self.colorIndex = colorIndex
        self.isOwner = isOwner; self.isKids = isKids; self.pinHash = pinHash
    }

    public var hasPin: Bool { pinHash != nil }

    public static func hashPin(_ pin: String, profileID: UUID) -> String {
        SHA256Digest.hex(of: profileID.uuidString + ":" + pin)
    }

    public func pinMatches(_ pin: String) -> Bool {
        guard let pinHash else { return true }
        return pinHash == Self.hashPin(pin, profileID: id)
    }
}

/// The household's profiles, persisted in the household directory.
public final class ProfileRoster: @unchecked Sendable {
    private let file: JSONFile<[Profile]>
    private let lock = NSLock()

    public init(scope: HouseholdScope) {
        file = scope.file("profiles.json")
    }

    /// Always at least one profile: the owner.
    public func load() -> [Profile] {
        lock.lock(); defer { lock.unlock() }
        if let profiles = file.load(), profiles.contains(where: \.isOwner) { return profiles }
        let owner = Profile(name: "Me", avatar: "person.fill", colorIndex: 0, isOwner: true)
        try? file.save([owner])
        return [owner]
    }

    public func save(_ profiles: [Profile]) {
        lock.lock(); defer { lock.unlock() }
        try? file.save(profiles)
    }
}
