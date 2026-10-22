import Foundation

/// What can be read off a stream's free-text name/title. Add-ons format this differently, so every
/// field is best effort and the ranking never depends on one add-on's conventions.
public struct StreamTraits: Hashable, Sendable {
    public enum Resolution: Int, Comparable, Sendable {
        case unknown = 0, sd = 1, hd720 = 2, hd1080 = 3, uhd4k = 4
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
        public var label: String? {
            switch self {
            case .uhd4k: "4K"
            case .hd1080: "1080p"
            case .hd720: "720p"
            case .sd: "SD"
            case .unknown: nil
            }
        }
    }

    public var resolution: Resolution
    public var isHDR: Bool
    public var isDolbyVision: Bool
    /// Ready to stream instantly from a debrid cache (`[RD+]`, `⚡`, "cached", ...).
    public var isCached: Bool
    /// Needs a debrid download first (`[RD download]`, "uncached").
    public var isUncached: Bool
    public var isCam: Bool
    public var sizeBytes: Int64?
    public var seeders: Int?
    public var codec: String?
    /// Untouched Blu-ray/UHD video and audio.
    public var isRemux: Bool
    public var audio: Audio?
    public var isAtmos: Bool
    /// 8 = 7.1, 6 = 5.1, 2 = stereo; nil when not stated.
    public var channels: Int?

    public enum Audio: String, Sendable {
        case trueHD = "TrueHD", dtsHDMA = "DTS-HD MA", dtsX = "DTS:X", eac3 = "DD+", ac3 = "DD", dts = "DTS", aac = "AAC"
        public var isLossless: Bool { self == .trueHD || self == .dtsHDMA || self == .dtsX }
    }

    public var audioLabel: String? {
        var parts: [String] = []
        if let audio { parts.append(audio.rawValue) }
        if isAtmos { parts.append("Atmos") }
        if let channels { parts.append(channels == 8 ? "7.1" : channels == 6 ? "5.1" : channels == 2 ? "2.0" : "\(channels)ch") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    public init(_ stream: AddonStream) {
        let text = ([stream.name, stream.title, stream.description, stream.behaviorHints?.filename]
            .compactMap { $0 }.joined(separator: " "))
        let lower = text.lowercased()

        func has(_ needles: [String]) -> Bool { needles.contains { lower.contains($0) } }

        if has(["2160p", "4k", "uhd"]) { resolution = .uhd4k }
        else if has(["1080p", "1080i", "fhd"]) { resolution = .hd1080 }
        else if has(["720p"]) { resolution = .hd720 }
        else if has(["480p", "576p", "360p", " sd "]) { resolution = .sd }
        else { resolution = .unknown }

        isDolbyVision = has(["dolby vision", "dovi", " dv ", ".dv.", "[dv]", "dv hdr", "hdr dv"])
        isHDR = isDolbyVision || has(["hdr", "hdr10"])
        isUncached = has(["uncached", "download]", "⏳"])
        isCached = !isUncached && (has(["+]", "⚡", "cached", "instant"]) || lower.contains("rd+"))
        isCam = has(["camrip", " cam ", "hdcam", " ts ", "telesync", "hdts", "telecine"])
        codec = has(["x265", "hevc", "h265", "h.265"]) ? "HEVC" : has(["av1"]) ? "AV1" : has(["x264", "h264", "avc"]) ? "H.264" : nil
        isRemux = has(["remux", "bdremux", "uhd bluray", "bdmv"]) && !has(["webrip", "web-dl", "web dl"])
        isAtmos = has(["atmos"])
        if has(["truehd", "true-hd"]) { audio = .trueHD }
        else if has(["dts:x", "dts-x", "dtsx"]) { audio = .dtsX }
        else if has(["dts-hd", "dts hd", "dtshd", "dts-ma", "dts ma"]) { audio = .dtsHDMA }
        else if has(["ddp", "dd+", "eac3", "e-ac-3", "e-ac3"]) { audio = .eac3 }
        else if has(["dts"]) { audio = .dts }
        else if has([" dd5", "dd 5", "ac3", " dd2"]) { audio = .ac3 }
        else if has(["aac"]) { audio = .aac }
        else { audio = nil }
        if has(["7.1", "7 1ch", "8ch"]) { channels = 8 }
        else if has(["5.1", "6ch"]) { channels = 6 }
        else if has(["2.0", "stereo"]) { channels = 2 }
        else { channels = nil }
        sizeBytes = stream.behaviorHints?.videoSize ?? Self.parseSize(text)
        seeders = Self.parseSeeders(text)
    }

    /// "💾 12.4 GB", "Size: 900 MB", "12.4GB".
    static func parseSize(_ text: String) -> Int64? {
        let pattern = #"(\d+(?:[.,]\d+)?)\s*(TB|GB|MB|GiB|MiB)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let numberRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text),
              let value = Double(text[numberRange].replacingOccurrences(of: ",", with: ".")) else { return nil }
        let unit = text[unitRange].uppercased()
        let multiplier: Double = unit.hasPrefix("T") ? 1_099_511_627_776 : unit.hasPrefix("G") ? 1_073_741_824 : 1_048_576
        return Int64(value * multiplier)
    }

    /// "👤 123", "Seeders: 45", "S: 12".
    static func parseSeeders(_ text: String) -> Int? {
        let pattern = #"(?:👤|seeders?:?|seeds?:?)\s*(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }
}

/// User preferences that steer automatic source choice.
public struct StreamPreferences: Codable, Hashable, Sendable {
    public var maxResolution: StreamTraits.Resolution.RawValue
    public var preferHDR: Bool
    public var hideCam: Bool
    /// Torrents need a streaming server; without one they are not playable on this device.
    public var allowTorrents: Bool

    public init(maxResolution: Int = StreamTraits.Resolution.uhd4k.rawValue, preferHDR: Bool = true,
                hideCam: Bool = true, allowTorrents: Bool = true) {
        self.maxResolution = maxResolution; self.preferHDR = preferHDR
        self.hideCam = hideCam; self.allowTorrents = allowTorrents
    }
}

/// Limits for a costly connection (cellular, a personal hotspot): a lower quality cap, and a strong
/// preference for sources that start at once and don't pull a huge file over the air.
public struct NetworkLimits: Hashable, Sendable {
    public var maxResolution: Int
    public init(maxResolution: Int) { self.maxResolution = maxResolution }
}

/// A stream with its parsed traits and where it came from.
public struct RankedStream: Hashable, Identifiable, Sendable {
    public var stream: AddonStream
    public var addon: Addon
    public var traits: StreamTraits
    public var score: Double
    /// Position the add-on gave it (add-ons already sort sensibly; we respect that as a tie-breaker).
    public var addonRank: Int

    public var id: String {
        addon.id + "|" + (stream.url?.absoluteString ?? stream.infoHash.map { "\($0):\(stream.fileIdx ?? -1)" } ?? "\(addonRank)")
    }
}

public enum StreamRanking {
    /// Flatten, filter, and score. The best candidate first.
    ///
    /// The order of concerns mirrors what a viewer cares about: it must start (cached debrid or a
    /// direct link beats a torrent that has to find peers), it must not be junk (CAM), then quality up
    /// to the user's cap, then size as a proxy for bitrate. Add-on order breaks ties.
    public static func rank(_ groups: [StreamGroup], preferences: StreamPreferences,
                            torrentsPlayable: Bool, limits: NetworkLimits? = nil) -> [RankedStream] {
        var preferences = preferences
        if let limits { preferences.maxResolution = min(preferences.maxResolution, limits.maxResolution) }
        var ranked: [RankedStream] = []
        for (groupIndex, group) in groups.enumerated() {
            for (index, stream) in group.streams.enumerated() {
                let isTorrent = stream.url == nil && stream.infoHash != nil
                guard stream.url != nil || (isTorrent && torrentsPlayable && preferences.allowTorrents) else { continue }
                let traits = StreamTraits(stream)
                if preferences.hideCam && traits.isCam { continue }
                let rank = groupIndex * 1000 + index
                ranked.append(RankedStream(stream: stream, addon: group.addon, traits: traits,
                                           score: score(traits, isTorrent: isTorrent, preferences: preferences, rank: rank,
                                                        constrained: limits != nil),
                                           addonRank: rank))
            }
        }
        return ranked.sorted { $0.score != $1.score ? $0.score > $1.score : $0.addonRank < $1.addonRank }
    }

    static func score(_ t: StreamTraits, isTorrent: Bool, preferences p: StreamPreferences, rank: Int,
                      constrained: Bool = false) -> Double {
        var s = 0.0
        // On cellular, a source that starts at once matters even more, and a torrent (peers, then the
        // whole swarm's overhead) or an uncached debrid file is the last resort.
        if constrained {
            if t.isCached { s += 2000 }
            if isTorrent || t.isUncached { s -= 2000 }
        }
        // Will it start?
        if t.isCached { s += 4000 }
        if t.isUncached { s -= 3000 }
        if isTorrent {
            s -= 1500
            if let seeders = t.seeders { s += min(Double(seeders), 200) * 4 } else { s -= 300 }
            if t.seeders == 0 { s -= 4000 }
        }
        // Quality, capped by preference: anything above the cap ranks below everything at or under it.
        let res = t.resolution.rawValue
        if res > p.maxResolution { s -= 2500 } else { s += Double(res) * 300 }
        if t.resolution == .unknown { s -= 150 }
        if p.preferHDR && t.isHDR && res <= p.maxResolution { s += 120 }
        if p.preferHDR && t.isDolbyVision && res <= p.maxResolution { s += 40 }
        // Home-theater quality inside the same resolution tier: untouched remux, lossless and object audio,
        // full surround. Each bonus is smaller than one resolution step, so a 1080p remux never outranks 4K.
        if res <= p.maxResolution, !constrained {
            if t.isRemux { s += 90 }
            if t.audio?.isLossless == true { s += 60 } else if t.audio == .eac3 { s += 20 }
            if t.isAtmos { s += 50 }
            if let channels = t.channels { s += channels >= 8 ? 30 : channels >= 6 ? 20 : 0 }
        }
        // Bigger file at the same tier usually means higher bitrate; log-scaled so it never dominates.
        // On cellular the opposite: the smaller file at the same tier plays smoother and costs less data.
        if let size = t.sizeBytes, size > 0 {
            let weight = min(log2(Double(size) / Double(1 << 20)), 18)
            s += constrained ? -weight * 30 : weight * 8
        }
        // Gentle preference for the add-on's own order.
        s -= Double(rank % 1000) * 0.5
        return s
    }
}
