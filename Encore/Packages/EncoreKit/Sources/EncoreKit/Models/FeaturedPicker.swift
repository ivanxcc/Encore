import Foundation

/// Chooses the titles in Home's hero, the way the Apple TV app curates its top shelf: a couple of shows
/// the viewer is in the middle of, then what is popular right now, movies and shows alternating, only
/// titles with real artwork, in an order that changes every day (and differs between profiles) instead
/// of always the same first six of the first catalog.
public enum FeaturedPicker {
    /// - Parameters:
    ///   - inProgress: the profile's Continue Watching titles, most recent first.
    ///   - trending: this week's trending titles (TMDB), best first; may be empty.
    ///   - catalogs: the Home catalogs' titles, in shelf order (the fallback pool when nothing trends).
    ///   - seed: varies the order; the app passes the day and the profile.
    public static func pick(inProgress: [MetaPreview], trending: [MetaPreview], catalogs: [[MetaPreview]],
                            seed: String, count: Int = 8) -> [MetaPreview] {
        var seen = Set<String>()
        func fresh(_ items: [MetaPreview]) -> [MetaPreview] {
            items.filter { hasArtwork($0) && seen.insert($0.id).inserted }
        }

        let personal = Array(fresh(Array(inProgress.filter { $0.type == "series" }.prefix(2))))

        // Popular now: trending when the cloud provides it, else the top of the Home catalogs.
        var pool = fresh(Array(trending.prefix(20)))
        if pool.count < count {
            let topOfCatalogs = catalogs.prefix(4).flatMap { Array($0.prefix(15)) }
            pool += fresh(topOfCatalogs)
        }
        // Titles that come with a known logo (TMDB) first: the hero sets the title's logo, not text. Each
        // half is shuffled for the day, then alternates movies and shows.
        var generator = SeededGenerator(seed: seed)
        let withLogo = pool.filter { $0.logo != nil }.shuffled(using: &generator)
        let withoutLogo = pool.filter { $0.logo == nil }.shuffled(using: &generator)
        let popular = alternate(withLogo) + alternate(withoutLogo)

        var picked: [MetaPreview] = []
        var personalQueue = personal
        for (index, item) in popular.enumerated() {
            // Personal picks lead and recur, but never crowd out what is new.
            if (index == 0 || index == 4), !personalQueue.isEmpty { picked.append(personalQueue.removeFirst()) }
            picked.append(item)
            if picked.count >= count { break }
        }
        picked += personalQueue
        return Array(picked.prefix(count))
    }

    static func hasArtwork(_ meta: MetaPreview) -> Bool {
        meta.background != nil || ArtworkURLs.backdrop(for: meta.id) != nil
    }

    /// Movie, show, movie, show… while both last, keeping each kind's order.
    static func alternate(_ items: [MetaPreview]) -> [MetaPreview] {
        var movies = items.filter { $0.type == "movie" }[...]
        var others = items.filter { $0.type != "movie" }[...]
        var result: [MetaPreview] = []
        while !movies.isEmpty || !others.isEmpty {
            if let movie = movies.popFirst() { result.append(movie) }
            if let other = others.popFirst() { result.append(other) }
        }
        return result
    }

    /// The seed the app uses: same order all day for a profile, a new one tomorrow.
    public static func dailySeed(profile: UUID?, date: Date = Date()) -> String {
        let day = Int(date.timeIntervalSince1970 / 86_400)
        return "\(day)|\(profile?.uuidString ?? "")"
    }
}

/// A small deterministic generator (SplitMix64), so "today's order" is stable across launches.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: String) {
        // FNV-1a of the seed text.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in seed.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        state = hash
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
