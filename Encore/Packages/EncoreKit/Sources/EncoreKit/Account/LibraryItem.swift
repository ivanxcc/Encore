import Foundation

/// A Stremio library item (datastore collection `libraryItem`). Field names and units match the
/// official clients exactly (offsets and durations in MILLISECONDS) so edits made here round-trip
/// through Stremio on every other device.
public struct StremioLibraryItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var type: String
    public var poster: URL?
    public var removed: Bool
    public var temp: Bool
    public var created: Date
    public var modified: Date
    public var state: State

    public struct State: Codable, Hashable, Sendable {
        public var lastWatched: Date?
        public var timeWatched: Int64
        /// Resume position in milliseconds.
        public var timeOffset: Int64
        /// Duration in milliseconds.
        public var duration: Int64
        /// The episode id the progress belongs to (series), or nil.
        public var videoID: String?
        public var timesWatched: Int
        public var flaggedWatched: Int

        public init() {
            timeWatched = 0; timeOffset = 0; duration = 0; timesWatched = 0; flaggedWatched = 0
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            lastWatched = (try? c.decodeIfPresent(String.self, forKey: .lastWatched)).flatMap(ISO8601.parse)
            timeWatched = Self.int64(c, .timeWatched)
            timeOffset = Self.int64(c, .timeOffset)
            duration = Self.int64(c, .duration)
            videoID = try? c.decodeIfPresent(String.self, forKey: .videoID)
            timesWatched = Int(Self.int64(c, .timesWatched))
            flaggedWatched = Int(Self.int64(c, .flaggedWatched))
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(lastWatched.map(ISO8601.format), forKey: .lastWatched)
            try c.encode(timeWatched, forKey: .timeWatched)
            try c.encode(timeOffset, forKey: .timeOffset)
            try c.encode(duration, forKey: .duration)
            try c.encodeIfPresent(videoID, forKey: .videoID)
            try c.encode(timesWatched, forKey: .timesWatched)
            try c.encode(flaggedWatched, forKey: .flaggedWatched)
        }

        private static func int64(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int64 {
            if let v = try? c.decodeIfPresent(Int64.self, forKey: key) { return v }
            if let v = try? c.decodeIfPresent(Double.self, forKey: key) { return Int64(v) }
            return 0
        }

        enum CodingKeys: String, CodingKey {
            case lastWatched, timeWatched, timeOffset, duration, timesWatched, flaggedWatched
            case videoID = "video_id"
        }
    }

    /// Fraction watched of the current video, 0...1.
    public var progress: Double {
        guard state.duration > 0 else { return 0 }
        return min(1, max(0, Double(state.timeOffset) / Double(state.duration)))
    }

    /// In Continue Watching: started, not finished, not removed.
    public var isInProgress: Bool {
        !removed && state.timeOffset > 0 && progress < 0.92
    }

    public var isInLibrary: Bool { !removed && !temp }

    public init(meta: MetaPreview, now: Date = Date()) {
        id = meta.id; name = meta.name; type = meta.type; poster = meta.poster
        removed = false; temp = true; created = now; modified = now; state = State()
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        type = (try? c.decode(String.self, forKey: .type)) ?? "movie"
        poster = c.url(.poster)
        removed = (try? c.decode(Bool.self, forKey: .removed)) ?? false
        temp = (try? c.decode(Bool.self, forKey: .temp)) ?? false
        created = (try? c.decode(String.self, forKey: .created)).flatMap(ISO8601.parse) ?? .distantPast
        modified = (try? c.decode(String.self, forKey: .modified)).flatMap(ISO8601.parse) ?? .distantPast
        state = (try? c.decode(State.self, forKey: .state)) ?? State()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(type, forKey: .type)
        try c.encode(poster?.absoluteString ?? "", forKey: .poster)
        try c.encode(removed, forKey: .removed)
        try c.encode(temp, forKey: .temp)
        try c.encode(ISO8601.format(created), forKey: .created)
        try c.encode(ISO8601.format(modified), forKey: .modified)
        try c.encode(state, forKey: .state)
    }

    enum CodingKeys: String, CodingKey {
        case id = "_id", name, type, poster, removed, temp, state
        case created = "_ctime", modified = "_mtime"
    }

    /// Record playback progress the way Stremio does.
    public mutating func recordProgress(videoID: String?, position: TimeInterval, duration: TimeInterval,
                                        now: Date = Date()) {
        if state.videoID != videoID { state.timeWatched = 0 }
        state.videoID = videoID
        state.timeOffset = Int64(max(0, position) * 1000)
        state.duration = Int64(max(0, duration) * 1000)
        state.lastWatched = now
        if duration > 0, position / duration >= 0.92 {
            state.timesWatched += 1
            state.flaggedWatched = 1
            state.timeOffset = 0
        }
        removed = false
        modified = now
    }
}
