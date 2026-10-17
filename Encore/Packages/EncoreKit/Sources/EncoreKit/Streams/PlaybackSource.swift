import Foundation

/// Everything the player needs for one attempt: the URL, required headers, and a hint about which
/// engine should open it.
public struct PlaybackSource: Hashable, Sendable {
    public enum Engine: String, Sendable {
        /// AVFoundation: MP4/MOV/HLS. Best power use, native PiP, AirPlay, HDR/Dolby Vision passthrough.
        case native
        /// libmpv: MKV and everything AVFoundation cannot demux.
        case mpv
    }

    public var url: URL
    public var headers: [String: String]
    public var preferredEngine: Engine
    public var title: String
    public var subtitles: [Subtitle]

    public init(url: URL, headers: [String: String] = [:], preferredEngine: Engine, title: String,
                subtitles: [Subtitle] = []) {
        self.url = url; self.headers = headers; self.preferredEngine = preferredEngine
        self.title = title; self.subtitles = subtitles
    }

    /// Resolve a stream against an optional streaming server (needed only for torrents).
    public static func resolve(_ stream: AddonStream, streamingServer: URL?, title: String) -> PlaybackSource? {
        let url: URL
        if let direct = stream.url {
            url = direct
        } else if let hash = stream.infoHash, let server = streamingServer,
                  hash.count == 40, hash.allSatisfy(\.isHexDigit) {
            url = server.appendingPathComponent(hash).appendingPathComponent(String(stream.fileIdx ?? -1))
        } else {
            return nil
        }
        let filename = stream.behaviorHints?.filename ?? url.lastPathComponent
        return PlaybackSource(url: url,
                              headers: stream.behaviorHints?.proxyHeaders?.request ?? [:],
                              preferredEngine: engine(forFilename: filename, isTorrent: stream.url == nil),
                              title: title,
                              subtitles: stream.subtitles ?? [])
    }

    /// AVFoundation only for containers it is known to open; everything else (MKV, AVI, TS, unknown)
    /// goes straight to libmpv, so the viewer never waits for a native attempt that cannot succeed.
    static func engine(forFilename filename: String, isTorrent: Bool) -> Engine {
        let ext = (filename as NSString).pathExtension.lowercased()
        if ["mp4", "m4v", "mov", "m3u8"].contains(ext) { return .native }
        return .mpv
    }
}
