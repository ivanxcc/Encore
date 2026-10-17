import AVFoundation
import AVKit
import CoreMedia
#if canImport(UIKit)
import UIKit
#endif

/// The dynamic range of what is playing, reduced to the display modes an Apple TV can switch into.
enum ContentDynamicRange: String {
    case sdr, hdr10, hlg, dolbyVision

    var label: String? {
        switch self {
        case .sdr: nil
        case .hdr10: "HDR10"
        case .hlg: "HLG"
        case .dolbyVision: "Dolby Vision"
        }
    }
}

/// Infuse-style "Match Content": asks the Apple TV to switch the HDMI output to the title's own frame
/// rate and dynamic range, so 23.976 fps films play without 3:2 judder and HDR lights the TV's HDR mode.
///
/// tvOS only honors the request when Settings > Video and Audio > Match Content is on; when it is off,
/// `isEnabledInSystemSettings` is false and the app tells the viewer where the switch lives.
///
/// The criteria are built with the public `AVDisplayCriteria(refreshRate:formatDescription:)` from a
/// synthetic format description (HEVC + PQ/HLG/BT.709, or 'dvh1' for Dolby Vision): the same technique
/// VortX settled on after the integer SPI proved unreliable across tvOS versions.
@MainActor
enum DisplayModeMatcher {
    static let enabledKey = "marquee.matchContent"
    static var isEnabledInApp: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    #if os(tvOS)
    private static var manager: AVDisplayManager? {
        #if targetEnvironment(simulator)
        return nil   // the simulator runtime does not implement avDisplayManager and crashes on access
        #else
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        return window?.avDisplayManager
        #endif
    }

    static var isEnabledInSystemSettings: Bool { manager?.isDisplayCriteriaMatchingEnabled ?? false }

    private static var lastRequest: String?

    /// Request a mode for the content. Returns false when the system setting is off (nothing was asked).
    @discardableResult
    static func request(_ range: ContentDynamicRange, fps: Double, width: Int, height: Int) -> Bool {
        guard isEnabledInApp, let manager, manager.isDisplayCriteriaMatchingEnabled else { return false }
        // An unknown frame rate is never guessed: a wrong rate is worse than leaving the panel alone.
        guard fps > 1 else { return false }
        let key = "\(range.rawValue)@\(String(format: "%.3f", fps))"
        guard key != lastRequest else { return true }
        guard let format = formatDescription(range, width: max(width, 1920), height: max(height, 1080)) else { return false }
        manager.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: Float(fps), formatDescription: format)
        lastRequest = key
        return true
    }

    /// Back to the home-screen mode when playback ends.
    static func reset() {
        lastRequest = nil
        manager?.preferredDisplayCriteria = nil
    }

    private static func formatDescription(_ range: ContentDynamicRange, width: Int, height: Int) -> CMFormatDescription? {
        let extensions: [CFString: Any]
        switch range {
        case .sdr:
            extensions = [
                kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
                kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_ITU_R_709_2,
                kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2,
            ]
        case .hlg:
            extensions = [
                kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
                kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG,
                kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
            ]
        case .hdr10, .dolbyVision:
            extensions = [
                kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
                kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ,
                kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
            ]
        }
        let codec: CMVideoCodecType = range == .dolbyVision ? kCMVideoCodecType_DolbyVisionHEVC : kCMVideoCodecType_HEVC
        var format: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: codec,
                                                    width: Int32(width), height: Int32(height),
                                                    extensions: extensions as CFDictionary, formatDescriptionOut: &format)
        return status == noErr ? format : nil
    }
    #else
    static var isEnabledInSystemSettings: Bool { false }
    @discardableResult
    static func request(_ range: ContentDynamicRange, fps: Double, width: Int, height: Int) -> Bool { false }
    static func reset() {}
    #endif
}
