import Foundation

/// What is really reaching the screen and speakers, shown in the player's info panel the way Infuse does,
/// so "is this actually Dolby Vision / 7.1?" has an answer on screen.
struct PlaybackInfo: Equatable {
    var width = 0
    var height = 0
    var frameRate = 0.0
    var dynamicRange: ContentDynamicRange = .sdr
    var videoCodec: String?
    var hardwareDecoding = false
    var audioCodec: String?
    var audioChannels = 0

    var resolutionLabel: String? {
        switch max(width, height * 16 / 9) {
        case 0: nil
        case 3200...: "4K"
        case 1700...: "1080p"
        case 1100...: "720p"
        default: "SD"
        }
    }

    var videoLine: String {
        var parts: [String] = []
        if let resolutionLabel { parts.append(resolutionLabel) }
        if let range = dynamicRange.label { parts.append(range) }
        if let videoCodec { parts.append(Self.codecName(videoCodec)) }
        if frameRate > 0 { parts.append(String(format: frameRate.rounded() == frameRate ? "%.0f fps" : "%.3f fps", frameRate)) }
        if videoCodec != nil { parts.append(hardwareDecoding ? "Hardware" : "Software") }
        return parts.joined(separator: " · ")
    }

    var audioLine: String {
        var parts: [String] = []
        if let audioCodec { parts.append(Self.codecName(audioCodec)) }
        if audioChannels > 0 { parts.append(Self.channelName(audioChannels)) }
        if audioCodec != nil, audioChannels > 0 { parts.append("PCM") }
        return parts.joined(separator: " · ")
    }

    static func codecName(_ codec: String) -> String {
        switch codec.lowercased() {
        case "hevc", "h265": "HEVC"
        case "h264", "avc": "H.264"
        case "av1": "AV1"
        case "vp9": "VP9"
        case "truehd": "Dolby TrueHD"
        case "eac3": "Dolby Digital Plus"
        case "ac3": "Dolby Digital"
        case "dts": "DTS"
        case "dts-hd", "dtshd": "DTS-HD"
        case "aac": "AAC"
        case "flac": "FLAC"
        case "opus": "Opus"
        default: codec.uppercased()
        }
    }

    static func channelName(_ channels: Int) -> String {
        switch channels {
        case 1: "Mono"
        case 2: "Stereo"
        case 6: "5.1"
        case 8: "7.1"
        default: "\(channels) ch"
        }
    }
}

/// Picture processing for the libmpv engine.
enum VideoQuality: String, CaseIterable, Identifiable {
    /// Sharp, efficient scalers; smooth on every Apple TV 4K generation.
    case balanced
    /// Infuse-class scaling and debanding for 1080p on a 4K panel. Best on Apple TV 4K (2022) and Macs.
    case high

    static let key = "encore.videoQuality"
    static var current: VideoQuality { VideoQuality(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .balanced }

    var id: String { rawValue }
    var label: String { self == .balanced ? "Balanced" : "High Quality" }

    var mpvOptions: [(String, String)] {
        switch self {
        case .balanced:
            return [("scale", "spline36"), ("cscale", "spline36"), ("dscale", "mitchell"),
                    ("deband", "no"), ("dither-depth", "auto")]
        case .high:
            return [("scale", "ewa_lanczossharp"), ("cscale", "ewa_lanczossharp"), ("dscale", "mitchell"),
                    ("correct-downscaling", "yes"), ("linear-downscaling", "yes"), ("sigmoid-upscaling", "yes"),
                    ("deband", "yes"), ("deband-iterations", "2"), ("dither-depth", "auto")]
        }
    }
}
