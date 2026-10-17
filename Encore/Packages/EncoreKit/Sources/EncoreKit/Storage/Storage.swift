import Foundation
#if canImport(Security)
import Security
#endif

/// Atomic JSON persistence for one Codable value at one path. Reads tolerate a missing or corrupt file
/// (they return nil) so a bad write can never brick launch.
public struct JSONFile<Value: Codable>: Sendable {
    public let url: URL

    public init(_ url: URL) { self.url = url }

    public func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Value.self, from: data)
    }

    public func save(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    public func remove() { try? FileManager.default.removeItem(at: url) }
}

/// Where secrets (session tokens, debrid keys) live. Namespaced per household, so one household can
/// never read another's credentials.
public protocol SecretStore: Sendable {
    func string(_ key: String) -> String?
    func set(_ value: String?, for key: String)
    func removeAll()
}

/// A 0600 JSON file. Used on macOS (the legacy login keychain prompts for unsigned builds, and the data
/// protection keychain needs entitlements an ad-hoc signed app does not have) and in tests.
public final class FileSecretStore: SecretStore, @unchecked Sendable {
    private let file: JSONFile<[String: String]>
    private let lock = NSLock()

    public init(url: URL) { file = JSONFile(url) }

    public func string(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return file.load()?[key]
    }

    public func set(_ value: String?, for key: String) {
        lock.lock(); defer { lock.unlock() }
        var all = file.load() ?? [:]
        all[key] = value
        try? file.save(all)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.url.path)
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        file.remove()
    }
}

#if canImport(Security) && !os(macOS)
/// The system Keychain, one service per household.
public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String) { self.service = service }

    private func query(_ key: String? = nil) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service]
        if let key { q[kSecAttrAccount as String] = key }
        return q
    }

    public func string(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func set(_ value: String?, for key: String) {
        guard let value, let data = value.data(using: .utf8) else {
            SecItemDelete(query(key) as CFDictionary)
            return
        }
        let status = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(key)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    public func removeAll() { SecItemDelete(query() as CFDictionary) }
}
#endif
