import Foundation

/// The public Stremio account API (api.strem.io): sign-in, the installed add-on collection, and the
/// library datastore. These are plain JSON POSTs; keeping them here means signing into an existing
/// Stremio account brings its add-ons, library, and watch progress with it.
public struct StremioAPI: Sendable {
    public static let defaultBase = URL(string: "https://api.strem.io/api/")!
    public let http: HTTPClient
    public let base: URL

    public init(http: HTTPClient = HTTPClient(), base: URL = StremioAPI.defaultBase) {
        self.http = http
        self.base = base
    }

    public struct User: Codable, Hashable, Sendable {
        public var id: String
        public var email: String
        enum CodingKeys: String, CodingKey { case id = "_id", email }
    }

    public struct Session: Codable, Hashable, Sendable {
        public var authKey: String
        public var user: User
    }

    public enum APIError: Error, Equatable, Sendable {
        case server(String)
        case empty
    }

    // MARK: Auth

    public func login(email: String, password: String) async throws -> Session {
        struct Body: Encodable { let type = "Login"; let email: String; let password: String; let facebook = false }
        return try await call("login", Body(email: email, password: password), as: Session.self)
    }

    public func logout(authKey: String) async {
        struct Body: Encodable { let type = "Logout"; let authKey: String }
        struct Ignored: Decodable {}
        _ = try? await call("logout", Body(authKey: authKey), as: Ignored.self)
    }

    /// Who a session belongs to. Used to confirm a session handed over by another device.
    public func user(authKey: String) async throws -> User {
        struct Body: Encodable { let type = "GetUser"; let authKey: String }
        return try await call("getUser", Body(authKey: authKey), as: User.self)
    }

    // MARK: Add-ons

    public func addonCollection(authKey: String) async throws -> [Addon] {
        struct Body: Encodable { let type = "AddonCollectionGet"; let authKey: String; let update = true }
        struct Result: Decodable { let addons: [Lossy<Descriptor>] }
        struct Descriptor: Decodable {
            let transportUrl: String
            let manifest: AddonManifest
            let flags: Flags?
            struct Flags: Decodable { let protected: Bool? }
        }
        let result = try await call("addonCollectionGet", Body(authKey: authKey), as: Result.self)
        return result.addons.compactMap(\.value).compactMap { d in
            URL(string: d.transportUrl).map { Addon(transportURL: $0, manifest: d.manifest,
                                                    isProtected: d.flags?.protected ?? false) }
        }
    }

    public func setAddonCollection(authKey: String, addons: [Addon]) async throws {
        struct Descriptor: Encodable {
            let transportUrl: String
            let manifest: AddonManifest
            let flags: [String: Bool]
        }
        struct Body: Encodable { let type = "AddonCollectionSet"; let authKey: String; let addons: [Descriptor] }
        struct Ignored: Decodable {}
        let descriptors = addons.map {
            Descriptor(transportUrl: $0.transportURL.absoluteString, manifest: $0.manifest,
                       flags: ["official": false, "protected": $0.isProtected])
        }
        _ = try await call("addonCollectionSet", Body(authKey: authKey, addons: descriptors), as: Ignored.self)
    }

    // MARK: Library

    public func library(authKey: String) async throws -> [StremioLibraryItem] {
        struct Body: Encodable {
            let authKey: String; let collection = "libraryItem"; let ids: [String] = []; let all = true
        }
        let items = try await call("datastoreGet", Body(authKey: authKey), as: [Lossy<StremioLibraryItem>].self)
        return items.compactMap(\.value)
    }

    public func putLibrary(authKey: String, items: [StremioLibraryItem]) async throws {
        struct Body: Encodable { let authKey: String; let collection = "libraryItem"; let changes: [StremioLibraryItem] }
        struct Ignored: Decodable {}
        guard !items.isEmpty else { return }
        _ = try await call("datastorePut", Body(authKey: authKey, changes: items), as: Ignored.self)
    }

    // MARK: Transport

    private struct Envelope<T: Decodable>: Decodable {
        let result: T?
        let error: ErrorBody?
        struct ErrorBody: Decodable { let message: String? }
    }

    private func call<Body: Encodable, T: Decodable>(_ method: String, _ body: Body, as: T.Type) async throws -> T {
        let envelope = try await http.post(base.appendingPathComponent(method), body: body, as: Envelope<T>.self)
        if let error = envelope.error { throw APIError.server(error.message ?? "Request failed") }
        guard let result = envelope.result else { throw APIError.empty }
        return result
    }
}
