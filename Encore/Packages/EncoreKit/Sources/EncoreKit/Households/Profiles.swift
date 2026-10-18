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
    /// When this profile was last edited, so Encore Cloud can keep the newest copy.
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, avatar: String = "person.fill", colorIndex: Int = 0,
                isOwner: Bool = false, isKids: Bool = false, pinHash: String? = nil, updatedAt: Date = Date()) {
        self.id = id; self.name = name; self.avatar = avatar; self.colorIndex = colorIndex
        self.isOwner = isOwner; self.isKids = isKids; self.pinHash = pinHash; self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        avatar = (try? c.decode(String.self, forKey: .avatar)) ?? "person.fill"
        colorIndex = (try? c.decode(Int.self, forKey: .colorIndex)) ?? 0
        isOwner = (try? c.decode(Bool.self, forKey: .isOwner)) ?? false
        isKids = (try? c.decode(Bool.self, forKey: .isKids)) ?? false
        pinHash = try? c.decodeIfPresent(String.self, forKey: .pinHash)
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? .distantPast
    }

    public var hasPin: Bool { pinHash != nil }

    /// Not tied to the profile's id, so a PIN keeps working on every device the profile syncs to.
    public static func hashPin(_ pin: String) -> String {
        SHA256Digest.hex(of: "encore.pin:" + pin)
    }

    public func pinMatches(_ pin: String) -> Bool {
        guard let pinHash else { return true }
        // Accept PINs set by builds that salted with the profile id.
        return pinHash == Self.hashPin(pin) || pinHash == SHA256Digest.hex(of: id.uuidString + ":" + pin)
    }

    /// The same profile with everything but the edit time compared.
    func sameContent(as other: Profile) -> Bool {
        var a = self, b = other
        a.updatedAt = .distantPast; b.updatedAt = .distantPast
        return a == b
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
        let owner = Profile(name: "Me", avatar: "person.fill", colorIndex: 0, isOwner: true, updatedAt: .distantPast)
        try? file.save([owner])
        return [owner]
    }

    public func save(_ profiles: [Profile]) {
        lock.lock(); defer { lock.unlock() }
        try? file.save(profiles)
    }
}
