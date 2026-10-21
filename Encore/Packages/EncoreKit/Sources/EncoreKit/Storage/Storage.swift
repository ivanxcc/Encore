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
        guard let data = (try? Data(contentsOf: url)) ?? DurableMirror.data(for: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Value.self, from: data)
    }

    public func save(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        DurableMirror.store(data, for: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    public func remove() {
        DurableMirror.store(nil, for: url)
        try? FileManager.default.removeItem(at: url)
    }
}

/// Where Encore keeps its files on this platform.
///
/// Apple TV allows an app to write only to its Caches folder on real hardware (writes to Application
/// Support and Documents are denied, though the simulator allows them), and the system may empty Caches
/// when storage runs low. So on tvOS files live in Caches, and the small ones that identify the
/// households and their accounts are also kept in the app's defaults (see `DurableMirror`).
public enum StorageLocation {
    public static var root: URL {
        #if os(tvOS)
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #endif
        return base.appendingPathComponent("Encore", isDirectory: true)
    }

    /// Whether a file can be written (and read back) where Encore keeps its data.
    public static func isWritable(_ directory: URL = root) -> Bool {
        let probe = directory.appendingPathComponent(".write-check")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("ok".utf8).write(to: probe, options: [.atomic])
            defer { try? FileManager.default.removeItem(at: probe) }
            return (try? Data(contentsOf: probe)) == Data("ok".utf8)
        } catch {
            return false
        }
    }
}

/// Apple TV: a copy of each small file in the app's defaults, which the system never purges, so the
/// household list, each household's account, and its profiles survive the system emptying Caches. Large
/// files (libraries) are not mirrored; they come back from the Stremio account and Encore Cloud.
/// Elsewhere this does nothing.
enum DurableMirror {
    /// Small enough to keep in defaults (Apple TV allows an app about 500 KB there in all).
    static let limit = 48 * 1024

    static func key(for url: URL) -> String? {
        let path = url.standardizedFileURL.path
        guard let range = path.range(of: "/Encore/") else { return nil }
        return "encore.file." + path[range.upperBound...]
    }

    static func data(for url: URL) -> Data? {
        #if os(tvOS)
        guard let key = key(for: url) else { return nil }
        return UserDefaults.standard.data(forKey: key)
        #else
        return nil
        #endif
    }

    static func store(_ data: Data?, for url: URL) {
        #if os(tvOS)
        guard let key = key(for: url) else { return }
        if let data, data.count <= limit {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        #endif
    }
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

    public init(service: String, fallback: FileSecretStore? = nil) {
        self.service = service
        self.fallback = fallback
    }

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
        if SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
            return String(data: data, encoding: .utf8)
        }
        return fallback?.string(key)
    }

    public func set(_ value: String?, for key: String) {
        guard let value, let data = value.data(using: .utf8) else {
            SecItemDelete(query(key) as CFDictionary)
            fallback?.set(nil, for: key)
            return
        }
        var status = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(key)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        // A build signed without Keychain access (some sideloading tools) can't keep secrets there; a
        // session that can't be saved must not silently read back as "signed out".
        fallback?.set(status == errSecSuccess ? nil : value, for: key)
    }

    public func removeAll() {
        SecItemDelete(query() as CFDictionary)
        fallback?.removeAll()
    }

    /// Where a secret goes when the Keychain refuses it.
    public var fallback: FileSecretStore?
}
#endif
