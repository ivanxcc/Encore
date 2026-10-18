import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Talks to Encore Cloud (Encore/Cloud, a Cloudflare Worker). Every call is made as a Stremio account:
/// the Worker checks the account's session with Stremio, so there is no second password to manage.
public struct CloudClient: Sendable {
    public let base: URL
    public let transport: HTTPTransport

    public init(base: URL, transport: HTTPTransport = URLSessionTransport()) {
        self.base = base
        self.transport = transport
    }

    /// The URL baked into this build (Info.plist `EncoreCloudURL`, set from the repository variable
    /// ENCORE_CLOUD_URL at release time), or nil when this build has no cloud.
    public static func configured(in bundle: Bundle = .main) -> CloudClient? {
        guard let raw = bundle.object(forInfoDictionaryKey: "EncoreCloudURL") as? String,
              !raw.isEmpty, !raw.hasPrefix("$("), let url = URL(string: raw), url.scheme == "https" else { return nil }
        return CloudClient(base: url)
    }

    public enum CloudError: Error, Equatable, Sendable {
        /// The Stremio session is no longer valid.
        case signedOut
        case notFound
        case expired
        case server(Int)
    }

    public struct Stored: Sendable, Equatable {
        public var version: Int
        public var document: HouseholdDocument
    }

    public enum PutResult: Sendable, Equatable {
        case saved(version: Int)
        /// Someone else saved first; here is what they saved.
        case conflict(Stored?)
    }

    // MARK: Household

    public func fetch(authKey: String) async throws -> Stored? {
        let (data, status) = try await send("GET", "v1/household", authKey: authKey)
        if status == 404 { return nil }
        try check(status)
        return try Self.stored(from: data)
    }

    public func put(_ document: HouseholdDocument, baseVersion: Int, authKey: String) async throws -> PutResult {
        let body = try JSONSerialization.data(withJSONObject: [
            "baseVersion": baseVersion,
            "doc": try JSONSerialization.jsonObject(with: document.encoded()),
        ])
        let (data, status) = try await send("PUT", "v1/household", authKey: authKey, body: body)
        if status == 409 {
            return .conflict(try? Self.stored(from: data))
        }
        try check(status)
        struct Saved: Decodable { let version: Int }
        return .saved(version: try JSONDecoder().decode(Saved.self, from: data).version)
    }

    public func deleteHousehold(authKey: String) async throws {
        let (_, status) = try await send("DELETE", "v1/household", authKey: authKey)
        try check(status)
    }

    // MARK: Sharing

    public struct Code: Decodable, Sendable, Equatable {
        public var code: String
        public var expiresAt: TimeInterval
        public var pollToken: String?
        public var expiry: Date { Date(timeIntervalSince1970: expiresAt) }
    }

    public struct Handoff: Decodable, Sendable, Equatable {
        public var ownerId: String
        public var email: String?
        public var authKey: String
        public var name: String?

        public var session: StremioAPI.Session {
            StremioAPI.Session(authKey: authKey, user: .init(id: ownerId, email: email ?? ""))
        }
    }

    /// The owner of a household creates a one-time code so someone else can manage it from their device.
    public func createShareCode(name: String, authKey: String) async throws -> Code {
        let (data, status) = try await send("POST", "v1/share", authKey: authKey, json: ["name": name])
        try check(status)
        return try JSONDecoder().decode(Code.self, from: data)
    }

    public func redeemShareCode(_ code: String, authKey: String) async throws -> Handoff {
        let (data, status) = try await send("POST", "v1/share/redeem", authKey: authKey, json: ["code": code])
        if status == 404 { throw CloudError.expired }
        try check(status)
        return try JSONDecoder().decode(Handoff.self, from: data)
    }

    // MARK: Signing in a TV

    public func startPairing() async throws -> Code {
        let (data, status) = try await send("POST", "v1/pair/start", authKey: nil)
        try check(status)
        return try JSONDecoder().decode(Code.self, from: data)
    }

    /// nil while the code is still waiting for a phone to approve it.
    public func pollPairing(token: String) async throws -> StremioAPI.Session? {
        var components = URLComponents(url: base.appendingPathComponent("v1/pair/poll"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        let (data, status) = try await send("GET", components.url!, authKey: nil, body: nil)
        if status == 202 { return nil }
        if status == 410 { throw CloudError.expired }
        try check(status)
        struct Approved: Decodable { let authKey: String; let email: String? }
        let approved = try JSONDecoder().decode(Approved.self, from: data)
        // The user id is filled in by the caller, which confirms the session with Stremio.
        return StremioAPI.Session(authKey: approved.authKey, user: .init(id: "", email: approved.email ?? ""))
    }

    public func approvePairing(code: String, authKey: String) async throws {
        let (_, status) = try await send("POST", "v1/pair/approve", authKey: authKey, json: ["code": code])
        if status == 404 { throw CloudError.expired }
        try check(status)
    }

    // MARK: Plumbing

    private static func stored(from data: Data) throws -> Stored? {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? Int else { return nil }
        guard let doc = object["doc"], !(doc is NSNull) else { return nil }
        let document = try HouseholdDocument.decode(JSONSerialization.data(withJSONObject: doc))
        return Stored(version: version, document: document)
    }

    private func check(_ status: Int) throws {
        if status == 401 { throw CloudError.signedOut }
        if status == 404 { throw CloudError.notFound }
        guard (200..<300).contains(status) else { throw CloudError.server(status) }
    }

    private func send(_ method: String, _ path: String, authKey: String?, json: [String: String]) async throws -> (Data, Int) {
        try await send(method, path, authKey: authKey, body: JSONSerialization.data(withJSONObject: json))
    }

    private func send(_ method: String, _ path: String, authKey: String?, body: Data? = nil) async throws -> (Data, Int) {
        try await send(method, base.appendingPathComponent(path), authKey: authKey, body: body)
    }

    private func send(_ method: String, _ url: URL, authKey: String?, body: Data?) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let authKey { request.setValue("Stremio \(authKey)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await transport.send(request)
        return (data, response.statusCode)
    }
}
