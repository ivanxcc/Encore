import XCTest
@testable import MarqueeKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Serves canned bodies by URL substring and records every request.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    var routes: [(String, Int, String)] = []
    var delays: [String: Duration] = [:]
    private(set) var requests: [URLRequest] = []
    private let lock = NSLock()

    func on(_ match: String, status: Int = 200, _ body: String) { routes.append((match, status, body)) }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        let url = request.url!.absoluteString
        if let delay = delays.first(where: { url.contains($0.key) })?.value { try await Task.sleep(for: delay) }
        guard let route = routes.first(where: { url.contains($0.0) }) else {
            throw URLError(.cannotConnectToHost)
        }
        return (Data(route.2.utf8), HTTPURLResponse(url: request.url!, statusCode: route.1, httpVersion: nil, headerFields: nil)!)
    }
}

private func addon(_ base: String, _ json: String) throws -> Addon {
    Addon(transportURL: URL(string: base + "/manifest.json")!,
          manifest: try JSONDecoder().decode(AddonManifest.self, from: Data(json.utf8)))
}

private let streamAddonJSON = """
{"id":"org.test.streams","version":"1.0.0","name":"Streams","resources":["stream"],"types":["movie","series"],"idPrefixes":["tt"],"catalogs":[]}
"""

final class ManifestTests: XCTestCase {
    func testDecodesMixedResourcesAndSkipsBadCatalogs() throws {
        let json = """
        {"id":"x","version":"1.2.3","name":"X","types":["movie"],
         "resources":["catalog",{"name":"stream","types":["series"],"idPrefixes":["kitsu:"]}],
         "catalogs":[{"type":"movie","id":"top","extra":[{"name":"search","isRequired":true}]},{"broken":true},{"type":"movie","id":"new"}],
         "logo":"", "unknownVendorKey": 42}
        """
        let manifest = try JSONDecoder().decode(AddonManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.resources.count, 2)
        XCTAssertEqual(manifest.catalogs.map(\.id), ["top", "new"])
        XCTAssertNil(manifest.logo)
        XCTAssertTrue(manifest.supports("stream", type: "series", id: "kitsu:1"))
        XCTAssertFalse(manifest.supports("stream", type: "series", id: "tt1"))
        XCTAssertFalse(manifest.supports("stream", type: "movie", id: "kitsu:1"))
        XCTAssertTrue(manifest.supports("catalog", type: "movie", id: nil))
        XCTAssertEqual(AddonService.homeCatalogs(from: [Addon(transportURL: URL(string: "https://a/manifest.json")!, manifest: manifest)]).map(\.catalog.id), ["new"])
    }

    func testManifestRoundTrips() throws {
        let data = try JSONEncoder().encode(DefaultAddons.cinemeta.manifest)
        let back = try JSONDecoder().decode(AddonManifest.self, from: data)
        XCTAssertEqual(back, DefaultAddons.cinemeta.manifest)
    }

    func testResourceURLEncoding() throws {
        let a = try addon("https://example.com/conf%7Bx%7D", streamAddonJSON)
        XCTAssertEqual(a.resourceURL("stream", type: "series", id: "tt0903747:1:2").absoluteString,
                       "https://example.com/conf%7Bx%7D/stream/series/tt0903747:1:2.json")
        XCTAssertEqual(a.resourceURL("catalog", type: "movie", id: "top", extra: [("search", "the office/us"), ("skip", "100")]).absoluteString,
                       "https://example.com/conf%7Bx%7D/catalog/movie/top/search=the%20office%2Fus&skip=100.json")
    }

    func testNormalizesInstallLinks() {
        XCTAssertEqual(AddonService.normalizedManifestURL("stremio://torrentio.strem.fun/manifest.json")?.absoluteString,
                       "https://torrentio.strem.fun/manifest.json")
        XCTAssertEqual(AddonService.normalizedManifestURL("https://x.io/abc/")?.absoluteString, "https://x.io/abc/manifest.json")
        XCTAssertEqual(AddonService.normalizedManifestURL("x.io")?.absoluteString, "https://x.io/manifest.json")
        XCTAssertNil(AddonService.normalizedManifestURL("ftp://x.io"))
    }
}

final class AddonServiceTests: XCTestCase {
    func testStreamsFanOutKeepsAddonOrderAndSurvivesFailures() async throws {
        let mock = MockTransport()
        mock.on("slow.test/stream", #"{"streams":[{"url":"https://cdn/slow.mkv","name":"slow"}]}"#)
        mock.on("bad.test/stream", status: 500, "oops")
        mock.on("fast.test/stream", #"{"streams":[{"url":"https://cdn/fast.mp4","name":"fast"},{"bogus":1}]}"#)
        mock.delays["slow.test"] = .milliseconds(150)
        let service = AddonService(http: HTTPClient(transport: mock, retryDelay: .milliseconds(1)))
        let addons = try ["https://slow.test", "https://bad.test", "https://fast.test"].map { try addon($0, streamAddonJSON) }
        let groups = await service.streams(type: "movie", id: "tt1", in: addons)
        XCTAssertEqual(groups.map(\.addon.baseURL.host), ["slow.test", "fast.test"])
        XCTAssertEqual(groups[1].streams.count, 2, "a malformed stream decodes as an empty stream, never fails the group")
        // 500 is transient: one retry, then dropped.
        XCTAssertEqual(mock.requests.filter { $0.url!.host == "bad.test" }.count, 2)
    }

    func testMetaFallsThroughToNextAddon() async throws {
        let mock = MockTransport()
        mock.on("first.test/meta", status: 404, "")
        mock.on("second.test/meta", #"{"meta":{"id":"tt1","type":"series","name":"Show","videos":[{"id":"tt1:1:2","name":"Two","season":1,"episode":2},{"id":"tt1:1:1","title":"One","season":"1","number":1},{"id":"tt1:0:1","name":"Special","season":0,"episode":1}]}}"#)
        let json = #"{"id":"m","version":"1","name":"M","resources":["meta"],"types":["series"],"catalogs":[]}"#
        let service = AddonService(http: HTTPClient(transport: mock, retryDelay: .milliseconds(1)))
        let meta = try await service.meta(type: "series", id: "tt1", in: [try addon("https://first.test", json), try addon("https://second.test", json)])
        XCTAssertEqual(meta.seasons, [1, 0])
        XCTAssertEqual(meta.episodes(inSeason: 1).map(\.title), ["One", "Two"])
    }

    func testSearchGroupsResultsPerCatalog() async throws {
        let mock = MockTransport()
        mock.on("search=dune", #"{"metas":[{"id":"tt1","type":"movie","name":"Dune"},{"id":"tt1","type":"movie","name":"Dune"},{"id":"tt2","type":"movie","name":"Dune 2","imdbRating":8.6}]}"#)
        let service = AddonService(http: HTTPClient(transport: mock))
        let results = await service.search("dune", in: DefaultAddons.all)
        XCTAssertEqual(results.count, 2, "movie + series top catalogs support search")
        XCTAssertEqual(results[0].1.map(\.id), ["tt1", "tt2"])
        XCTAssertEqual(results[0].1[1].imdbRating, "8.6")
    }
}

final class RankingTests: XCTestCase {
    private func group(_ streams: [AddonStream]) throws -> StreamGroup {
        StreamGroup(addon: try addon("https://s.test", streamAddonJSON), streams: streams)
    }

    func testCachedDirectBeatsHigherResolutionTorrent() throws {
        let torrent = AddonStream(infoHash: String(repeating: "a", count: 40), name: "Torrentio\n4K", title: "Movie.2160p.HDR\n👤 5 💾 40 GB")
        let cached = AddonStream(url: URL(string: "https://rd/1080.mkv")!, name: "[RD+] Torrentio\n1080p", title: "Movie.1080p.x265\n💾 8.2 GB")
        let ranked = StreamRanking.rank([try group([torrent, cached])], preferences: StreamPreferences(), torrentsPlayable: true)
        XCTAssertEqual(ranked.first?.stream, cached)
        XCTAssertEqual(ranked.first?.traits.resolution, .hd1080)
        XCTAssertEqual(ranked.first?.traits.codec, "HEVC")
        XCTAssertEqual(ranked.last?.traits.seeders, 5)
        XCTAssertEqual(ranked.last?.traits.sizeBytes, 40 * 1_073_741_824)
    }

    func testTorrentsDroppedWithoutServerAndCamHidden() throws {
        let torrent = AddonStream(infoHash: String(repeating: "b", count: 40), name: "1080p")
        let cam = AddonStream(url: URL(string: "https://x/cam.mp4")!, name: "HDCAM 1080p", title: "Movie HDCAM")
        let good = AddonStream(url: URL(string: "https://x/good.mp4")!, name: "720p")
        let ranked = StreamRanking.rank([try group([torrent, cam, good])], preferences: StreamPreferences(), torrentsPlayable: false)
        XCTAssertEqual(ranked.map(\.stream), [good])
    }

    func testResolutionCapPushesAboveCapDown() throws {
        let uhd = AddonStream(url: URL(string: "https://x/4k.mkv")!, name: "[RD+] 4K")
        let hd = AddonStream(url: URL(string: "https://x/1080.mkv")!, name: "[RD+] 1080p")
        var prefs = StreamPreferences()
        prefs.maxResolution = StreamTraits.Resolution.hd1080.rawValue
        let ranked = StreamRanking.rank([try group([uhd, hd])], preferences: prefs, torrentsPlayable: false)
        XCTAssertEqual(ranked.first?.stream, hd)
    }

    func testPlaybackSourceResolution() {
        let hash = String(repeating: "c", count: 40)
        let torrent = AddonStream(infoHash: hash, fileIdx: 2)
        XCTAssertNil(PlaybackSource.resolve(torrent, streamingServer: nil, title: "t"))
        let source = PlaybackSource.resolve(torrent, streamingServer: URL(string: "http://192.168.1.5:11470")!, title: "t")
        XCTAssertEqual(source?.url.absoluteString, "http://192.168.1.5:11470/\(hash)/2")
        XCTAssertEqual(source?.preferredEngine, .mpv)
        let mp4 = PlaybackSource.resolve(AddonStream(url: URL(string: "https://x/a.mp4?sig=1")!), streamingServer: nil, title: "t")
        XCTAssertEqual(mp4?.preferredEngine, .native)
        var hinted = AddonStream(url: URL(string: "https://x/resolve/abc")!)
        hinted.behaviorHints = .init(filename: "Movie.2024.mkv", proxyHeaders: .init(request: ["Referer": "https://x"]))
        let mkv = PlaybackSource.resolve(hinted, streamingServer: nil, title: "t")
        XCTAssertEqual(mkv?.preferredEngine, .mpv)
        XCTAssertEqual(mkv?.headers["Referer"], "https://x")
    }
}

final class LibraryTests: XCTestCase {
    func testLibraryItemDecodesStremioShapeAndRoundTrips() throws {
        let json = """
        {"_id":"tt1","name":"Show","type":"series","poster":"https://p/1.jpg","removed":false,"temp":false,
         "_ctime":"2024-01-01T00:00:00.000Z","_mtime":"2024-02-01T10:00:00.000Z",
         "state":{"lastWatched":"2024-02-01T10:00:00.000Z","timeOffset":600000,"duration":2400000.0,"video_id":"tt1:1:3","timesWatched":0,"flaggedWatched":0}}
        """
        let item = try JSONDecoder().decode(StremioLibraryItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.progress, 0.25, accuracy: 0.0001)
        XCTAssertEqual(item.state.videoID, "tt1:1:3")
        XCTAssertTrue(item.isInProgress && item.isInLibrary)
        let back = try JSONDecoder().decode(StremioLibraryItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(back, item)
        let raw = String(data: try JSONEncoder().encode(item), encoding: .utf8)!
        XCTAssertTrue(raw.contains("\"_id\"") && raw.contains("\"video_id\"") && raw.contains("\"_mtime\""))
    }

    func testFinishingClearsResume() {
        var item = StremioLibraryItem(meta: MetaPreview(id: "tt2", type: "movie", name: "M"))
        item.recordProgress(videoID: nil, position: 1200, duration: 6000)
        XCTAssertTrue(item.isInProgress)
        item.recordProgress(videoID: nil, position: 5800, duration: 6000)
        XCTAssertFalse(item.isInProgress)
        XCTAssertEqual(item.state.timesWatched, 1)
    }
}

final class HouseholdTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("marquee-tests-\(UUID().uuidString)")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func directory() -> HouseholdDirectory {
        HouseholdDirectory(root: root) { _, dir in FileSecretStore(url: dir.appendingPathComponent("secrets.json")) }
    }

    func testHouseholdsAreIsolated() throws {
        let dir = directory()
        let home = dir.registry().households[0]
        let sister = dir.add(name: "Sister")
        let a = HouseholdSession(scope: dir.scope(for: home))
        let b = HouseholdSession(scope: dir.scope(for: sister))

        a.scope.secrets.set("token-a", for: "stremio.authKey")
        let ownerA = a.profiles()[0]
        let movie = MetaPreview(id: "tt9", type: "movie", name: "Mine")
        a.recordProgress(movie, videoID: nil, position: 100, duration: 1000, for: ownerA)
        a.updateSettings { $0.streamingServer = URL(string: "http://10.0.0.2:11470") }

        let ownerB = b.profiles()[0]
        XCTAssertFalse(b.isSignedIn)
        XCTAssertTrue(b.continueWatching(for: ownerB).isEmpty)
        XCTAssertNil(b.settings.streamingServer)
        XCTAssertEqual(a.continueWatching(for: ownerA).map(\.id), ["tt9"])

        // A fresh session over the same scope sees persisted state (relaunch).
        let reopened = HouseholdSession(scope: dir.scope(for: home))
        XCTAssertEqual(reopened.continueWatching(for: ownerA).map(\.id), ["tt9"])
        XCTAssertTrue(reopened.isSignedIn)

        // Deleting the non-active household removes its data and secrets.
        dir.delete(sister.id)
        XCTAssertEqual(dir.registry().households.map(\.id), [home.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.directory(for: sister.id).path))
        dir.delete(home.id)
        XCTAssertEqual(dir.registry().households.count, 1, "the open household cannot be deleted")
    }

    func testProfilesKeepSeparateLibraries() {
        let dir = directory()
        let session = HouseholdSession(scope: dir.scope(for: dir.registry().households[0]))
        var profiles = session.profiles()
        let kid = Profile(name: "Kid", isKids: true, pinHash: nil)
        profiles.append(kid)
        session.saveProfiles(profiles)
        let owner = profiles[0]
        let movie = MetaPreview(id: "tt5", type: "movie", name: "M")
        session.setInLibrary(movie, true, for: kid)
        XCTAssertEqual(session.myList(for: kid).map(\.id), ["tt5"])
        XCTAssertTrue(session.myList(for: owner).isEmpty)
        session.saveProfiles([kid])   // refuses to drop the owner
        XCTAssertEqual(session.profiles().count, 2)
    }

    func testPinHash() {
        var p = Profile(name: "P")
        p.pinHash = Profile.hashPin("1234", profileID: p.id)
        XCTAssertTrue(p.pinMatches("1234"))
        XCTAssertFalse(p.pinMatches("4321"))
        XCTAssertEqual(SHA256Digest.hex(of: "abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256Digest.portable(Array("abc".utf8)).map { String(format: "%02x", $0) }.joined(),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

final class AccountTests: XCTestCase {
    func testSignInPullsAddonsAndLibraryAndPushesEdits() async throws {
        let mock = MockTransport()
        mock.on("/login", #"{"result":{"authKey":"KEY","user":{"_id":"u1","email":"me@x.com"}}}"#)
        mock.on("/addonCollectionGet", #"{"result":{"addons":[{"transportUrl":"https://s.test/manifest.json","manifest":\#(streamAddonJSON),"flags":{"protected":false}},{"broken":true}]}}"#)
        mock.on("/datastoreGet", #"{"result":[{"_id":"tt7","name":"Remote","type":"movie","_mtime":"2024-01-01T00:00:00Z","state":{"timeOffset":5000,"duration":10000}}]}"#)
        mock.on("/datastorePut", #"{"result":{"success":true}}"#)
        mock.on("/logout", #"{"result":{}}"#)
        let http = HTTPClient(transport: mock)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("marquee-acct-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = HouseholdDirectory(root: root) { _, d in FileSecretStore(url: d.appendingPathComponent("s.json")) }
        let session = HouseholdSession(scope: dir.scope(for: dir.registry().households[0]),
                                       addonService: AddonService(http: http), api: StremioAPI(http: http))
        try await session.signIn(email: "me@x.com", password: "pw")
        XCTAssertTrue(session.isSignedIn)
        XCTAssertEqual(session.settings.accountEmail, "me@x.com")
        XCTAssertEqual(session.settings.addons.map(\.manifest.id), ["org.test.streams"])
        let owner = session.profiles()[0]
        XCTAssertEqual(session.continueWatching(for: owner).map(\.id), ["tt7"])

        let login = try XCTUnwrap(mock.requests.first { $0.url!.path.hasSuffix("login") })
        let body = try JSONSerialization.jsonObject(with: login.httpBody!) as! [String: Any]
        XCTAssertEqual(body["type"] as? String, "Login")

        session.recordProgress(MetaPreview(id: "tt8", type: "movie", name: "New"), videoID: nil, position: 60, duration: 600, for: owner)
        await session.pushPendingLibraryChanges()
        let put = try XCTUnwrap(mock.requests.last { $0.url!.path.hasSuffix("datastorePut") })
        let putBody = try JSONSerialization.jsonObject(with: put.httpBody!) as! [String: Any]
        let changes = putBody["changes"] as! [[String: Any]]
        XCTAssertEqual(changes.first?["_id"] as? String, "tt8")

        await session.signOut()
        XCTAssertFalse(session.isSignedIn)
        XCTAssertTrue(session.continueWatching(for: owner).isEmpty)
        XCTAssertEqual(session.settings.addons.map(\.manifest.id), ["com.linvo.cinemeta"])
    }

    func testServerErrorSurfaces() async {
        let mock = MockTransport()
        mock.on("/login", #"{"error":{"message":"Wrong password"}}"#)
        let api = StremioAPI(http: HTTPClient(transport: mock))
        do {
            _ = try await api.login(email: "a", password: "b")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? StremioAPI.APIError, .server("Wrong password"))
        }
    }
}

final class ArtworkTests: XCTestCase {
    func testMetahubFallbacks() {
        XCTAssertEqual(ArtworkURLs.backdrop(for: "tt0903747:1:2")?.absoluteString, "https://images.metahub.space/background/large/tt0903747/img")
        XCTAssertNil(ArtworkURLs.logo(for: "kitsu:123"))
        let meta = MetaPreview(id: "tt1", type: "movie", name: "M", background: URL(string: "https://own/bg.jpg"))
        XCTAssertEqual(meta.backdropURL?.absoluteString, "https://own/bg.jpg")
    }
}

final class PlaybackPlanTests: XCTestCase {
    private func ranked(_ streams: [AddonStream]) throws -> [RankedStream] {
        let a = try addon("https://s.test", streamAddonJSON)
        return streams.enumerated().map { RankedStream(stream: $1, addon: a, traits: StreamTraits($1), score: 0, addonRank: $0) }
    }

    func testAutomaticPlanIsBoundedAndFallsBackNativeToMPV() throws {
        let candidates = try ranked([
            AddonStream(url: URL(string: "https://x/1.mp4")!),
            AddonStream(infoHash: String(repeating: "a", count: 40)),   // unplayable without a server: skipped
            AddonStream(url: URL(string: "https://x/2.mkv")!),
            AddonStream(url: URL(string: "https://x/3.mkv")!),
            AddonStream(url: URL(string: "https://x/4.mkv")!),
        ])
        let plan = PlaybackPlan(candidates: candidates, explicit: false, streamingServer: nil, title: "t")
        XCTAssertEqual(plan.attempts.map(\.engine), [.native, .mpv, .mpv, .mpv])
        XCTAssertEqual(plan.attempts.map(\.candidate), [0, 0, 2, 3])
        XCTAssertEqual(Set(plan.attempts.map(\.candidate)).count, PlaybackPlan.maxSources)
    }

    func testExplicitPickNeverSwapsSource() throws {
        let candidates = try ranked([AddonStream(url: URL(string: "https://x/pick.mkv")!), AddonStream(url: URL(string: "https://x/other.mkv")!)])
        let plan = PlaybackPlan(candidates: Array(candidates.prefix(1)), explicit: true, streamingServer: nil, title: "t")
        XCTAssertEqual(plan.attempts.map(\.source.url.lastPathComponent), ["pick.mkv"])
    }
}

final class QualityTraitTests: XCTestCase {
    func testDetectsHomeTheaterAudioAndRemux() {
        let t = StreamTraits(AddonStream(url: URL(string: "https://x/a.mkv")!, name: "[RD+] 4K DV",
                                         title: "Dune.Part.Two.2024.2160p.UHD.BluRay.REMUX.DV.HDR.HEVC.TrueHD.Atmos.7.1"))
        XCTAssertTrue(t.isRemux && t.isAtmos && t.isDolbyVision)
        XCTAssertEqual(t.audio, .trueHD)
        XCTAssertEqual(t.channels, 8)
        XCTAssertEqual(t.audioLabel, "TrueHD Atmos 7.1")
        let web = StreamTraits(AddonStream(url: URL(string: "https://x/b.mkv")!, name: "1080p", title: "Show.S01E01.1080p.WEB-DL.DDP5.1.H.264"))
        XCTAssertFalse(web.isRemux)
        XCTAssertEqual(web.audio, .eac3)
        XCTAssertEqual(web.channels, 6)
    }

    func testRemuxWinsWithinTierButNeverBeatsHigherResolution() throws {
        let a = try addon("https://s.test", streamAddonJSON)
        let remux1080 = AddonStream(url: URL(string: "https://x/r.mkv")!, name: "[RD+] 1080p", title: "Movie.1080p.BluRay.REMUX.TrueHD.Atmos.7.1")
        let web1080 = AddonStream(url: URL(string: "https://x/w.mkv")!, name: "[RD+] 1080p", title: "Movie.1080p.WEB-DL.DDP5.1")
        let web4k = AddonStream(url: URL(string: "https://x/4.mkv")!, name: "[RD+] 4K", title: "Movie.2160p.WEB-DL.DDP5.1")
        let ranked = StreamRanking.rank([StreamGroup(addon: a, streams: [web1080, remux1080, web4k])],
                                        preferences: StreamPreferences(), torrentsPlayable: false)
        XCTAssertEqual(ranked.map(\.stream), [web4k, remux1080, web1080])
    }
}
