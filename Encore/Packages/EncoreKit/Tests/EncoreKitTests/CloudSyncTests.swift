import XCTest
@testable import EncoreKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An in-memory Encore Cloud that behaves like the Worker: one versioned document per account.
final class FakeCloud: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: (version: Int, doc: Any)] = [:]
    private(set) var puts = 0
    /// Simulates another device saving between this device's read and write.
    var interleave: (() -> Void)?

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let key = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let respond = { (status: Int, body: Any) -> (Data, HTTPURLResponse) in
            (try! JSONSerialization.data(withJSONObject: body),
             HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        guard key.hasPrefix("Stremio ") else { return respond(401, ["error": "signed out"]) }
        if request.httpMethod == "PUT", let hook = interleave { interleave = nil; hook() }
        return lock.withLock {
            switch request.httpMethod {
            case "GET":
                guard let row = stored[key] else { return respond(404, ["error": "none"]) }
                return respond(200, ["version": row.version, "doc": row.doc])
            case "PUT":
                let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                let base = body["baseVersion"] as! Int
                let current = stored[key]?.version ?? 0
                guard base == current else {
                    return respond(409, ["version": current, "doc": stored[key]?.doc ?? NSNull()])
                }
                puts += 1
                stored[key] = (current + 1, body["doc"]!)
                return respond(200, ["version": current + 1])
            default:
                return respond(404, ["error": "?"])
            }
        }
    }
}

final class CloudSyncTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { roots.forEach { try? FileManager.default.removeItem(at: $0) } }

    /// A fresh "device": its own directory, signed in to the same Stremio account.
    private func device(key: String = "KEY") -> HouseholdSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("encore-cloud-\(UUID().uuidString)")
        roots.append(root)
        let dir = HouseholdDirectory(root: root) { _, d in FileSecretStore(url: d.appendingPathComponent("s.json")) }
        let session = HouseholdSession(scope: dir.scope(for: dir.registry().households[0]))
        session.scope.secrets.set(key, for: "stremio.authKey")
        return session
    }

    private let movie = MetaPreview(id: "tt1", type: "movie", name: "Movie")

    func testProfilesHistoryAndSettingsReachASecondDevice() async throws {
        let cloud = FakeCloud()
        let sync = CloudSync(client: CloudClient(base: URL(string: "https://cloud.test")!, transport: cloud))

        let living = device()
        var profiles = living.profiles()
        profiles[0].name = "Ivan"
        let will = Profile(name: "Will", avatar: "star.fill", colorIndex: 2)
        profiles.append(will)
        profiles.append(Profile(name: "TV", avatar: "tv.fill"))
        living.saveProfiles(profiles)
        living.recordProgress(movie, videoID: nil, position: 600, duration: 6000, for: will)
        living.updateSettings { $0.streamingServer = URL(string: "http://nas.local:11470") }
        let first = try await sync.sync(living, name: "Ivan & Will", symbol: "heart.fill")
        XCTAssertEqual(first?.pushed, true)

        // A brand-new Apple TV signs in to the same account: everything appears, nothing to push back.
        let tv = device()
        let outcome = try await sync.sync(tv, name: "Home", symbol: "house.fill")
        XCTAssertEqual(outcome?.name, "Ivan & Will")
        XCTAssertEqual(outcome?.symbol, "heart.fill")
        XCTAssertEqual(outcome?.pushed, false)
        XCTAssertEqual(tv.profiles().map(\.name), ["Ivan", "Will", "TV"])
        let tvWill = try XCTUnwrap(tv.profiles().first { $0.name == "Will" })
        XCTAssertEqual(tvWill.id, will.id)
        XCTAssertEqual(tv.continueWatching(for: tvWill).map(\.id), ["tt1"])
        XCTAssertEqual(tv.settings.streamingServer?.host, "nas.local")

        // Syncing again with no edits is a no-op.
        let puts = cloud.puts
        _ = try await sync.sync(tv, name: "Ivan & Will", symbol: "heart.fill")
        _ = try await sync.sync(living, name: "Ivan & Will", symbol: "heart.fill")
        XCTAssertEqual(cloud.puts, puts)
    }

    func testConcurrentEditsOnTwoDevicesBothSurvive() async throws {
        let cloud = FakeCloud()
        let sync = CloudSync(client: CloudClient(base: URL(string: "https://cloud.test")!, transport: cloud))
        let phone = device()
        phone.saveProfiles(phone.profiles() + [Profile(name: "Will"), Profile(name: "Kid", isKids: true)])
        _ = try await sync.sync(phone, name: "Home", symbol: "house.fill")
        let tv = device()
        _ = try await sync.sync(tv, name: "Home", symbol: "house.fill")

        // The phone deletes Kid and the TV records progress for Will, without syncing in between.
        phone.saveProfiles(phone.profiles().filter { $0.name != "Kid" }, now: Date().addingTimeInterval(5))
        let tvWill = try XCTUnwrap(tv.profiles().first { $0.name == "Will" })
        tv.recordProgress(movie, videoID: nil, position: 100, duration: 1000, for: tvWill)

        _ = try await sync.sync(phone, name: "Home", symbol: "house.fill")
        _ = try await sync.sync(tv, name: "Home", symbol: "house.fill")
        _ = try await sync.sync(phone, name: "Home", symbol: "house.fill")

        for session in [phone, tv] {
            XCTAssertEqual(session.profiles().map(\.name).sorted(), ["Me", "Will"])
            let w = try XCTUnwrap(session.profiles().first { $0.name == "Will" })
            XCTAssertEqual(session.continueWatching(for: w).map(\.id), ["tt1"])
        }
    }

    func testConflictIsMergedAndRetried() async throws {
        let cloud = FakeCloud()
        let client = CloudClient(base: URL(string: "https://cloud.test")!, transport: cloud)
        let sync = CloudSync(client: client)
        let a = device()
        _ = try await sync.sync(a, name: "Home", symbol: "house.fill")
        let b = device()
        b.saveProfiles(b.profiles() + [Profile(name: "From B")])
        a.saveProfiles(a.profiles() + [Profile(name: "From A")])
        // B saves while A is between its read and its write.
        cloud.interleave = {
            Task { _ = try? await sync.sync(b, name: "Home", symbol: "house.fill") }
            Thread.sleep(forTimeInterval: 0.3)
        }
        _ = try await sync.sync(a, name: "Home", symbol: "house.fill")
        _ = try await sync.sync(b, name: "Home", symbol: "house.fill")
        XCTAssertEqual(Set(a.profiles().map(\.name)), ["Me", "From A", "From B"])
        XCTAssertEqual(Set(b.profiles().map(\.name)), ["Me", "From A", "From B"])
    }

    func testSameNamedProfilesFromTwoDevicesBecomeOne() {
        let shared = Profile(name: "Will", updatedAt: Date(timeIntervalSince1970: 100))
        let owner = Profile(name: "Ivan", isOwner: true, updatedAt: Date(timeIntervalSince1970: 50))
        let settings = HouseholdDocument.SyncedSettings(streamingServer: nil, preferences: StreamPreferences(), updatedAt: .distantPast)
        let remote = HouseholdDocument(name: "Home", symbol: "house.fill", nameUpdatedAt: .distantPast,
                                       profiles: [owner, shared], settings: settings)
        let localWill = Profile(name: "will", updatedAt: Date(timeIntervalSince1970: 10))
        var item = StremioLibraryItem(meta: movie, now: Date(timeIntervalSince1970: 200))
        item.temp = false
        let local = HouseholdDocument(name: "Home", symbol: "house.fill", nameUpdatedAt: .distantPast,
                                      profiles: [Profile(name: "Me", isOwner: true, updatedAt: .distantPast), localWill],
                                      libraries: [localWill.id.uuidString: [item]], settings: settings)
        let merged = HouseholdDocument.merge(local: local, remote: remote)
        XCTAssertEqual(merged.profiles.map(\.name), ["Ivan", "Will"])
        XCTAssertEqual(merged.libraries[shared.id.uuidString]?.map(\.id), ["tt1"])
    }

    func testSignedOutHouseholdDoesNotSync() async throws {
        let session = device()
        session.scope.secrets.set(nil, for: "stremio.authKey")
        let sync = CloudSync(client: CloudClient(base: URL(string: "https://cloud.test")!, transport: FakeCloud()))
        let outcome = try await sync.sync(session, name: "Home", symbol: "house.fill")
        XCTAssertNil(outcome)
    }

    func testPinsWorkOnEveryDevice() {
        var p = Profile(name: "Kid")
        p.pinHash = Profile.hashPin("2468")
        p.id = UUID()
        XCTAssertTrue(p.pinMatches("2468"))
        var legacy = Profile(name: "Old")
        legacy.pinHash = SHA256Digest.hex(of: legacy.id.uuidString + ":1111")
        XCTAssertTrue(legacy.pinMatches("1111"))
    }
}
