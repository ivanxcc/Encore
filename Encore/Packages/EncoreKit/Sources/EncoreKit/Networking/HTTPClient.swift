import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The single seam between EncoreKit and the network, so every client is testable with canned
/// responses and the app can swap in a configured session.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public enum HTTPError: Error, Equatable, Sendable {
    case status(Int)
    case invalidResponse
    case decoding(String)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HTTPError.invalidResponse }
        return (data, http)
    }

    /// A session tuned for add-on traffic: short connect timeouts (a dead add-on must not stall a
    /// screen), a generous disk cache (catalogs and metadata are cache-friendly), no cookies.
    public static func makeDefault() -> URLSessionTransport {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.requestCachePolicy = .useProtocolCachePolicy
        #if canImport(FoundationNetworking)
        config.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 128 << 20, diskPath: "encore-http")
        #else
        config.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 128 << 20, directory: nil)
        #endif
        config.httpMaximumConnectionsPerHost = 6
        return URLSessionTransport(session: URLSession(configuration: config))
    }
}

/// JSON over `HTTPTransport`, with one bounded retry for transient failures.
public struct HTTPClient: Sendable {
    public let transport: HTTPTransport
    public var retryDelay: Duration

    public init(transport: HTTPTransport = URLSessionTransport.makeDefault(), retryDelay: Duration = .milliseconds(400)) {
        self.transport = transport
        self.retryDelay = retryDelay
    }

    public func get<T: Decodable>(_ url: URL, as type: T.Type, timeout: TimeInterval = 15) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await decode(T.self, from: send(request))
    }

    public func post<Body: Encodable, T: Decodable>(_ url: URL, body: Body, as type: T.Type) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await decode(T.self, from: send(request))
    }

    func send(_ request: URLRequest) async throws -> Data {
        do {
            return try await attempt(request)
        } catch let error where Self.isTransient(error) && request.httpMethod != "POST" {
            try await Task.sleep(for: retryDelay)
            return try await attempt(request)
        }
    }

    private func attempt(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else { throw HTTPError.status(response.statusCode) }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw HTTPError.decoding(String(describing: error)) }
    }

    static func isTransient(_ error: Error) -> Bool {
        if let http = error as? HTTPError, case let .status(code) = http { return code == 429 || code >= 500 }
        if error is CancellationError { return false }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        return [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost,
                NSURLErrorDNSLookupFailed, NSURLErrorNotConnectedToInternet].contains(ns.code)
    }
}
