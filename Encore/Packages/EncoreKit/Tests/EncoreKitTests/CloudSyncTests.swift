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
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let key = auth + " " + (request.url?.path ?? "")
        let respond = { (status: Int, body: Any) -> (Data, HTTPURLResponse) in
            (try! JSONSerialization.data(withJSONObject: body),
             HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        guard auth.hasPrefix("Stremio ") else { return respond(401, ["error": "signed out"]) }
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

final class LegacyProfilesSyncTests: XCTestCase {
    /// Profiles saved by builds before Encore Cloud have no `updatedAt`. A fresh Apple TV signing in to
    /// the same account must still receive all of them.
    func testProfilesFromBeforeCloudReachANewTV() async throws {
        let cloud = FakeCloud()
        let sync = CloudSync(client: CloudClient(base: URL(string: "https://cloud.test")!, transport: cloud))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("encore-legacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        func device(_ name: String) -> HouseholdSession {
            let dir = HouseholdDirectory(root: root.appendingPathComponent(name)) { _, d in FileSecretStore(url: d.appendingPathComponent("s.json")) }
            let session = HouseholdSession(scope: dir.scope(for: dir.registry().households[0]))
            session.scope.secrets.set("KEY", for: "stremio.authKey")
            return session
        }
        let mac = device("mac")
        let legacy = """
        [{"id":"\(UUID().uuidString)","name":"Ivan","avatar":"person.fill","colorIndex":0,"isOwner":true,"isKids":false},
         {"id":"\(UUID().uuidString)","name":"Will","avatar":"star.fill","colorIndex":2,"isOwner":false,"isKids":false},
         {"id":"\(UUID().uuidString)","name":"TV","avatar":"tv.fill","colorIndex":3,"isOwner":false,"isKids":false}]
        """
        try Data(legacy.utf8).write(to: mac.scope.directory.appendingPathComponent("profiles.json"))
        XCTAssertEqual(mac.profiles().map(\.name), ["Ivan", "Will", "TV"])
        _ = try await sync.sync(mac, name: "Home", symbol: "house.fill")

        let tv = device("tv")
        _ = try await sync.sync(tv, name: "Home", symbol: "house.fill")
        XCTAssertEqual(tv.profiles().map(\.name), ["Ivan", "Will", "TV"])
    }
}

final class DirectorySyncTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { roots.forEach { try? FileManager.default.removeItem(at: $0) } }

    private func makeDevice() -> HouseholdDirectory {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("encore-dir-\(UUID().uuidString)")
        roots.append(root)
        return HouseholdDirectory(root: root) { _, d in FileSecretStore(url: d.appendingPathComponent("s.json")) }
    }

    private func signIn(_ directory: HouseholdDirectory, _ household: Household, user: String, key: String, shared: Bool? = nil) throws {
        try HouseholdSession(scope: directory.scope(for: household))
            .store(.init(authKey: key, user: .init(id: user, email: user + "@x.com")), sharedWithMe: shared)
    }

    func testHouseholdsFollowTheHomeAccountToEveryDevice() async throws {
        let cloud = FakeCloud()
        let client = CloudClient(base: URL(string: "https://cloud.test")!, transport: cloud)
        let sync = DirectorySync(client: client)

        // The Mac: Ivan's home, his sister's household (shared with him), and one with no Stremio account.
        let mac = makeDevice()
        let macHome = mac.registry().households[0]
        try signIn(mac, macHome, user: "ivan", key: "KEY-IVAN")
        let sister = mac.add(name: "Sarah", symbol: "person.2.fill")
        try signIn(mac, sister, user: "sarah", key: "KEY-SARAH", shared: true)
        let grandma = mac.add(name: "Grandma", symbol: "heart.fill")
        let grandmaSession = HouseholdSession(scope: mac.scope(for: grandma))
        grandmaSession.saveProfiles(grandmaSession.profiles() + [Profile(name: "Grandpa")])
        let first = try await sync.sync(mac, activeID: macHome.id)
        XCTAssertEqual(first?.pushed, true)
        XCTAssertEqual(DirectorySync.home(in: mac)?.id, macHome.id)

        // A new Apple TV signs in as Ivan: both other households appear, Sarah's signed in, Grandma's with her profiles.
        let tv = makeDevice()
        let tvHome = tv.registry().households[0]
        try signIn(tv, tvHome, user: "ivan", key: "KEY-IVAN")
        let tvResult = try await sync.sync(tv, activeID: tvHome.id)
        let outcome = try XCTUnwrap(tvResult)
        XCTAssertEqual(Set(outcome.added.map(\.name)), ["Sarah", "Grandma"])
        let tvSarah = try XCTUnwrap(tv.household(boundTo: "sarah"))
        XCTAssertEqual(HouseholdSession(scope: tv.scope(for: tvSarah)).cloudAuthKey, "KEY-SARAH")
        XCTAssertEqual(tv.settings(for: tvSarah)?.isSharedWithMe, true)
        let tvGrandma = try XCTUnwrap(tv.registry().households.first { $0.id == grandma.id })
        XCTAssertEqual(HouseholdSession(scope: tv.scope(for: tvGrandma)).profiles().map(\.name), ["Me", "Grandpa"])
        XCTAssertEqual(DirectorySync.home(in: tv)?.id, tvHome.id)

        // Nothing changed: no more writes.
        let puts = cloud.puts
        _ = try await sync.sync(tv, activeID: tvHome.id)
        _ = try await sync.sync(mac, activeID: macHome.id)
        XCTAssertEqual(cloud.puts, puts)

        // Removing Grandma on the Mac removes it from the TV; a profile added on the TV reaches the Mac.
        mac.delete(grandma.id)
        let tvSarahSession = HouseholdSession(scope: tv.scope(for: tvSarah))
        XCTAssertNotNil(tvSarahSession.cloudAuthKey)
        _ = try await sync.sync(mac, activeID: macHome.id)
        let removal = try await sync.sync(tv, activeID: tvHome.id)
        XCTAssertEqual(removal?.removed, [grandma.id])
        XCTAssertFalse(tv.registry().households.contains { $0.id == grandma.id })
        XCTAssertNotNil(tv.household(boundTo: "sarah"))
    }

    func testLocalHouseholdProfilesMergeAcrossDevices() async throws {
        let sync = DirectorySync(client: CloudClient(base: URL(string: "https://cloud.test")!, transport: FakeCloud()))
        let a = makeDevice(), b = makeDevice()
        for device in [a, b] { try signIn(device, device.registry().households[0], user: "ivan", key: "KEY-IVAN") }
        let kids = a.add(name: "Cabin", symbol: "tree.fill")
        _ = try await sync.sync(a, activeID: a.registry().activeID)
        _ = try await sync.sync(b, activeID: b.registry().activeID)
        let bCabin = HouseholdSession(scope: b.scope(for: try XCTUnwrap(b.registry().households.first { $0.id == kids.id })))
        bCabin.saveProfiles(bCabin.profiles() + [Profile(name: "Guest")], now: Date().addingTimeInterval(5))
        _ = try await sync.sync(b, activeID: b.registry().activeID)
        _ = try await sync.sync(a, activeID: a.registry().activeID)
        XCTAssertEqual(HouseholdSession(scope: a.scope(for: kids)).profiles().map(\.name), ["Me", "Guest"])
    }

    func testNoSignedInHouseholdMeansNoDirectory() async throws {
        let sync = DirectorySync(client: CloudClient(base: URL(string: "https://cloud.test")!, transport: FakeCloud()))
        let device = makeDevice()
        let outcome = try await sync.sync(device, activeID: device.registry().activeID)
        XCTAssertNil(outcome)
    }

    func testSharedHouseholdIsNeverHome() throws {
        let device = makeDevice()
        let first = device.registry().households[0]
        try signIn(device, first, user: "sarah", key: "KEY-SARAH", shared: true)
        let mine = device.add(name: "Mine")
        try signIn(device, mine, user: "ivan", key: "KEY-IVAN")
        XCTAssertEqual(DirectorySync.home(in: device)?.id, mine.id)
    }
}
