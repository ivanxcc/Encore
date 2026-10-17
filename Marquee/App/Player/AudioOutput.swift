import AVFoundation

/// How audio leaves the device.
///
/// Apple TV cannot bitstream DTS or TrueHD from a third-party app (VortX found the app-side S/PDIF path
/// froze playback), so, like Infuse, everything libmpv plays is decoded on device to multichannel LPCM:
/// lossless TrueHD / DTS-HD MA arrive at the receiver as up to 7.1 uncompressed PCM. Dolby Digital Plus
/// with Atmos in MP4/HLS goes through AVFoundation, which passes Atmos through untouched.
enum AudioOutputMode: String, CaseIterable, Identifiable {
    case auto
    case stereo

    static let key = "marquee.audioOutput"
    static var current: AudioOutputMode { AudioOutputMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .auto }

    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "Auto (up to 7.1)"
        case .stereo: "Stereo"
        }
    }
}

enum AudioSessionConfigurator {
    /// Ask the route for as many channels as it can take (HDMI/eARC up to 8) before playback starts, so the
    /// player negotiates the full layout instead of a stereo downmix. Returns the channel count granted.
    @discardableResult
    static func configureForPlayback() -> Int {
        #if os(iOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
        guard AudioOutputMode.current != .stereo else {
            try? session.setPreferredOutputNumberOfChannels(2)
            try? session.setActive(true)
            return 2
        }
        try? session.setSupportsMultichannelContent(true)
        let maximum = min(max(session.maximumOutputNumberOfChannels, 2), 8)
        try? session.setPreferredOutputNumberOfChannels(maximum)
        try? session.setActive(true)
        return max(session.outputNumberOfChannels, 2)
        #else
        return 8   // macOS: CoreAudio follows the output device's own channel layout
        #endif
    }

    /// The libmpv `audio-channels` policy for that route.
    static func mpvChannelPolicy(granted: Int) -> String {
        switch AudioOutputMode.current {
        case .stereo: return "stereo"
        case .auto: return granted > 2 ? "auto" : "auto-safe"
        }
    }
}
