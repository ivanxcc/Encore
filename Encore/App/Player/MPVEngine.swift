import Foundation
import SwiftUI
import QuartzCore
import Metal
import Libmpv
import EncoreKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// libmpv engine (via the public MPVKit package) for everything AVFoundation cannot open: MKV, AVI,
/// TS, unusual codecs, embedded ASS/PGS subtitles. Renders with gpu-next over MoltenVK into a Metal
/// layer, decodes with VideoToolbox, and runs on Apple silicon and Intel Macs alike.
@MainActor
final class MPVEngine: ObservableObject, PlayerEngine {
    var onEvent: ((PlayerEvent) -> Void)?
    let metalLayer = MPVMetalLayer()

    @Published private(set) var isPaused = false
    @Published private(set) var audioTracks: [MediaTrack] = []
    @Published private(set) var subtitleTracks: [MediaTrack] = []
    /// What is actually being decoded and output, for the info panel ("4K · Dolby Vision · TrueHD 7.1").
    @Published private(set) var info = PlaybackInfo()

    /// The mpv handle is used from mpv's own event queue, so it is not actor-isolated.
    nonisolated(unsafe) private var handle: OpaquePointer?
    private let eventQueue = DispatchQueue(label: "encore.mpv.events", qos: .userInitiated)
    private var started = false
    private var pendingSubtitles: [Subtitle] = []
    private var retainedSelf: Unmanaged<MPVEngine>?

    init() {
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.framebufferOnly = true
        // Fixed-size swapchain. MPVKit's moltenvk render context never notices a layer resize, so a
        // drawable that followed the window (window -> full screen, rotation, the window settling after
        // the first frame) left mpv drawing at the old size: the "video stays small" glitch. Instead the
        // drawable is the display's own resolution from the start, set before the first file loads, and
        // Core Animation scales it into whatever frame the view has, keeping the aspect ratio.
        metalLayer.drawableSize = Self.displayPixelSize
        metalLayer.contentsGravity = .resizeAspect
        metalLayer.needsDisplayOnBoundsChange = false
        create()
    }

    private func create() {
        guard let mpv = mpv_create() else { return }
        handle = mpv
        let grantedChannels = AudioSessionConfigurator.configureForPlayback()
        var layer = metalLayer
        mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &layer)
        var options: [(String, String)] = [
            ("vo", "gpu-next"),
            ("gpu-api", "vulkan"),
            ("gpu-context", "moltenvk"),
            // Hardware decode for H.264/HEVC/VP9 (and AV1 on chips that have it); libmpv falls back to software
            // per stream, which is why MKV, 10-bit HEVC, and AV1 that the stock iOS player rejects still play.
            ("hwdec", "videotoolbox"),
            ("hwdec-codecs", "all"),
            // HDR: tag the output with the content's own transfer function (set per file in applyDynamicRange),
            // measure peaks for tone mapping only when the display cannot show HDR.
            ("target-colorspace-hint", "yes"),
            ("hdr-compute-peak", "auto"),
            ("tone-mapping", "auto"),
            // With the TV switched to the content's frame rate, audio-clock sync is exact; no resampling games.
            ("video-sync", "audio"),
            ("interpolation", "no"),
            // Decode every codec (TrueHD, DTS-HD MA, E-AC-3) to multichannel PCM for the route the session granted.
            ("ao", Self.audioOutputDriver),
            ("audio-channels", AudioSessionConfigurator.mpvChannelPolicy(granted: grantedChannels)),
            ("audio-normalize-downmix", "yes"),
            ("cache", "yes"),
            ("demuxer-max-bytes", "400MiB"),
            ("demuxer-max-back-bytes", "100MiB"),
            ("demuxer-readahead-secs", "45"),
            ("network-timeout", "25"),
            ("keep-open", "no"),
            ("idle", "yes"),
            ("ytdl", "no"),
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("terminal", "no"),
            ("msg-level", "all=warn"),
            ("sub-auto", "fuzzy"),
            ("sub-ass-override", "no"),     // keep styled anime/foreign subtitles exactly as authored
            ("slang", Self.preferredLanguages),
            ("alang", Self.preferredLanguages),
            ("subs-fallback", "default"),
            ("user-agent", "Encore/1.0"),
        ]
        options += VideoQuality.current.mpvOptions
        for (name, value) in options { mpv_set_option_string(mpv, name, value) }
        guard mpv_initialize(mpv) >= 0 else {
            mpv_terminate_destroy(mpv)
            handle = nil
            return
        }
        mpv_observe_property(mpv, 1, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 2, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 3, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 4, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 5, "track-list/count", MPV_FORMAT_INT64)
        mpv_observe_property(mpv, 6, "video-params/gamma", MPV_FORMAT_STRING)
        mpv_observe_property(mpv, 7, "audio-params/channel-count", MPV_FORMAT_INT64)

        // The callback fires on an mpv thread. It holds a retained reference released in stop(), so it
        // can never outlive the engine.
        let retained = Unmanaged.passRetained(self)
        retainedSelf = retained
        mpv_set_wakeup_callback(mpv, { context in
            guard let context else { return }
            Unmanaged<MPVEngine>.fromOpaque(context).takeUnretainedValue().wakeUp()
        }, retained.toOpaque())
    }

    /// The largest display's pixel size in landscape, capped at 4K so Intel and older Macs with 5K/6K
    /// panels do not render more pixels than the content has.
    static var displayPixelSize: CGSize {
        #if os(macOS)
        let sizes = NSScreen.screens.map { CGSize(width: $0.frame.width * $0.backingScaleFactor,
                                                  height: $0.frame.height * $0.backingScaleFactor) }
        let largest = sizes.max { $0.width * $0.height < $1.width * $1.height } ?? CGSize(width: 2880, height: 1800)
        #else
        let native = (UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
                      ?? UIScreen.main).nativeBounds.size
        let largest = CGSize(width: max(native.width, native.height), height: min(native.width, native.height))
        #endif
        let scale = min(1, 3840 / max(largest.width, 1), 2160 / max(largest.height, 1))
        return CGSize(width: (largest.width * scale).rounded(), height: (largest.height * scale).rounded())
    }

    private static var audioOutputDriver: String {
        #if os(macOS)
        return "coreaudio"
        #else
        return "audiounit"
        #endif
    }

    private static var preferredLanguages: String {
        let codes = Locale.preferredLanguages.compactMap { Locale(identifier: $0).language.languageCode?.identifier(.alpha3) }
        return (codes + ["eng", "en"]).joined(separator: ",")
    }

    // MARK: Commands

    func load(_ source: PlaybackSource, startAt: TimeInterval) {
        guard let mpv = handle else { onEvent?(.failed("The player could not start.")); return }
        started = false
        pendingSubtitles = source.subtitles
        let headers = source.headers.map { "\($0.key): \($0.value)" }.joined(separator: ",")
        mpv_set_property_string(mpv, "http-header-fields", headers)
        mpv_set_property_string(mpv, "force-media-title", source.title)
        var args = ["loadfile", source.url.absoluteString, "replace"]
        if startAt > 1 { args += ["-1", "start=\(Int(startAt))"] }
        command(args)
        setPaused(false)
    }

    func play() { setPaused(false) }
    func pause() { setPaused(true) }

    func seek(to seconds: TimeInterval) {
        command(["seek", String(max(0, seconds)), "absolute+keyframes"])
    }

    func selectAudio(_ id: Int) {
        guard let mpv = handle else { return }
        mpv_set_property_string(mpv, "aid", String(id))
        refreshTracks()
    }

    func selectSubtitle(_ id: Int?) {
        guard let mpv = handle else { return }
        mpv_set_property_string(mpv, "sid", id.map(String.init) ?? "no")
        refreshTracks()
    }

    func stop() {
        DisplayModeMatcher.reset()
        guard let mpv = handle else { return }
        handle = nil
        mpv_set_wakeup_callback(mpv, nil, nil)
        let retained = retainedSelf
        retainedSelf = nil
        // Destroy off the main thread: tearing down the demuxer can block on the network.
        eventQueue.async {
            mpv_terminate_destroy(mpv)
            DispatchQueue.main.async { retained?.release() }
        }
    }

    private func setPaused(_ paused: Bool) {
        guard let mpv = handle else { return }
        mpv_set_property_string(mpv, "pause", paused ? "yes" : "no")
        isPaused = paused
    }

    private func command(_ args: [String]) {
        guard let mpv = handle else { return }
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer { cargs.forEach { if let p = $0 { free(UnsafeMutablePointer(mutating: p)) } } }
        mpv_command(mpv, &cargs)
    }

    // MARK: Events

    nonisolated private func wakeUp() {
        eventQueue.async { [weak self] in self?.drainEvents() }
    }

    nonisolated private func drainEvents() {
        while let mpv = handle {
            guard let event = mpv_wait_event(mpv, 0) else { return }
            let id = event.pointee.event_id
            if id == MPV_EVENT_NONE { return }
            switch id {
            case MPV_EVENT_PLAYBACK_RESTART:
                DispatchQueue.main.async { [weak self] in self?.handleRestart() }
            case MPV_EVENT_VIDEO_RECONFIG:
                DispatchQueue.main.async { [weak self] in self?.applyDynamicRange() }
            case MPV_EVENT_FILE_LOADED:
                DispatchQueue.main.async { [weak self] in self?.handleFileLoaded() }
            case MPV_EVENT_END_FILE:
                guard let data = event.pointee.data else { break }
                let endFile = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                if endFile.reason == MPV_END_FILE_REASON_EOF {
                    DispatchQueue.main.async { [weak self] in self?.onEvent?(.ended) }
                } else if endFile.reason == MPV_END_FILE_REASON_ERROR {
                    let message = String(cString: mpv_error_string(endFile.error))
                    DispatchQueue.main.async { [weak self] in self?.onEvent?(.failed("Couldn't open this source (\(message)).")) }
                }
            case MPV_EVENT_PROPERTY_CHANGE:
                guard let data = event.pointee.data else { break }
                let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
                handleProperty(property)
            case MPV_EVENT_SHUTDOWN:
                return
            default:
                break
            }
        }
    }

    nonisolated private func handleProperty(_ property: mpv_event_property) {
        let name = String(cString: property.name)
        switch (name, property.format) {
        case ("time-pos", MPV_FORMAT_DOUBLE), ("duration", MPV_FORMAT_DOUBLE):
            guard let mpv = handle else { return }
            var position = 0.0, duration = 0.0
            mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &position)
            mpv_get_property(mpv, "duration", MPV_FORMAT_DOUBLE, &duration)
            DispatchQueue.main.async { [weak self] in self?.onEvent?(.progress(position: position, duration: duration)) }
        case ("paused-for-cache", MPV_FORMAT_FLAG):
            let buffering = property.data.map { $0.assumingMemoryBound(to: Int32.self).pointee != 0 } ?? false
            DispatchQueue.main.async { [weak self] in self?.onEvent?(.buffering(buffering)) }
        case ("pause", MPV_FORMAT_FLAG):
            let paused = property.data.map { $0.assumingMemoryBound(to: Int32.self).pointee != 0 } ?? false
            DispatchQueue.main.async { [weak self] in self?.isPaused = paused }
        case ("track-list/count", _):
            DispatchQueue.main.async { [weak self] in self?.refreshTracks() }
        case ("video-params/gamma", _):
            DispatchQueue.main.async { [weak self] in self?.applyDynamicRange() }
        case ("audio-params/channel-count", _):
            DispatchQueue.main.async { [weak self] in self?.refreshInfo() }
        default:
            break
        }
    }

    private func handleRestart() {
        guard !started else { onEvent?(.buffering(false)); return }
        started = true
        onEvent?(.started)
    }

    private func handleFileLoaded() {
        for subtitle in pendingSubtitles {
            command(["sub-add", subtitle.url.absoluteString, "auto", subtitle.lang, subtitle.lang])
        }
        pendingSubtitles = []
        refreshTracks()
    }

    // MARK: Output quality

    private func string(_ property: String) -> String? {
        guard let mpv = handle, let raw = mpv_get_property_string(mpv, property) else { return nil }
        defer { mpv_free(raw) }
        let value = String(cString: raw)
        return value.isEmpty ? nil : value
    }

    private func double(_ property: String) -> Double {
        guard let mpv = handle else { return 0 }
        var value = 0.0
        mpv_get_property(mpv, property, MPV_FORMAT_DOUBLE, &value)
        return value
    }

    /// Chapter titles and start times embedded in the file (used for skip markers when no database has them).
    func chapters() -> [(title: String, start: TimeInterval)] {
        let count = Int(double("chapter-list/count"))
        guard count > 0 else { return [] }
        return (0..<count).compactMap { index in
            guard let title = string("chapter-list/\(index)/title") else { return nil }
            return (title, double("chapter-list/\(index)/time"))
        }
    }

    private var appliedRange: ContentDynamicRange?

    /// Output the content's real dynamic range instead of a tone-mapped SDR picture:
    ///  - tvOS: switch the TV into the matching HDMI mode (and frame rate), then render PQ/HLG into a layer
    ///    tagged with that colorspace. Dolby Vision on this engine is output as HDR10 (libplacebo applies the
    ///    DV reshaping, so profile 5 colors are right); true DV signalling needs the native engine.
    ///  - iPhone/iPad/Mac: render into an EDR layer when the screen has HDR headroom, else tone map to SDR.
    private func applyDynamicRange() {
        guard let mpv = handle else { return }
        let gamma = string("video-params/gamma") ?? ""
        let isDolbyVision = string("current-tracks/video/dolby-vision-profile") != nil
        var range: ContentDynamicRange
        switch gamma {
        case "pq": range = isDolbyVision ? .dolbyVision : .hdr10
        case "hlg": range = .hlg
        default: range = isDolbyVision ? .dolbyVision : .sdr
        }
        if range != .sdr && !Self.displaySupportsHDR { range = .sdr }
        refreshInfo(range: range)
        guard range != appliedRange else { return }
        appliedRange = range

        let outputRange: ContentDynamicRange = range == .dolbyVision ? .hdr10 : range
        mpv_set_property_string(mpv, "target-trc", outputRange == .hdr10 ? "pq" : outputRange == .hlg ? "hlg" : "auto")
        mpv_set_property_string(mpv, "target-prim", outputRange == .sdr ? "auto" : "bt.2020")
        switch outputRange {
        case .hdr10, .dolbyVision: metalLayer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
        case .hlg: metalLayer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)
        case .sdr: metalLayer.colorspace = nil
        }
        #if os(iOS) || os(macOS)
        metalLayer.wantsExtendedDynamicRangeContent = outputRange != .sdr
        #endif
        #if os(tvOS)
        let fps = double("container-fps") > 0 ? double("container-fps") : double("estimated-vf-fps")
        DisplayModeMatcher.request(outputRange, fps: fps,
                                   width: Int(double("video-params/w")), height: Int(double("video-params/h")))
        #endif
    }

    private static var displaySupportsHDR: Bool {
        #if os(iOS)
        return (UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first?.potentialEDRHeadroom ?? 1) > 1
        #elseif os(macOS)
        return (NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1
        #else
        return true   // tvOS: the HDMI mode switch decides; the TV tone maps if it must
        #endif
    }

    private func refreshInfo(range: ContentDynamicRange? = nil) {
        var next = info
        if let range { next.dynamicRange = range }
        next.width = Int(double("video-params/w"))
        next.height = Int(double("video-params/h"))
        next.frameRate = double("container-fps")
        next.videoCodec = string("current-tracks/video/codec")
        next.hardwareDecoding = (string("hwdec-current") ?? "no") != "no"
        next.audioCodec = string("current-tracks/audio/codec")
        next.audioChannels = Int(double("audio-params/channel-count"))
        if next != info { info = next }
    }

    private func refreshTracks() {
        guard let mpv = handle else { return }
        func string(_ path: String) -> String? {
            guard let raw = mpv_get_property_string(mpv, path) else { return nil }
            defer { mpv_free(raw) }
            return String(cString: raw)
        }
        let count = Int(string("track-list/count") ?? "0") ?? 0
        var audio: [MediaTrack] = [], subs: [MediaTrack] = []
        for index in 0..<count {
            let base = "track-list/\(index)"
            guard let type = string(base + "/type"), let id = Int(string(base + "/id") ?? "") else { continue }
            let lang = string(base + "/lang").map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }
            let title = [lang, string(base + "/title")].compactMap { $0 }.joined(separator: " · ")
            let track = MediaTrack(id: id, title: title.isEmpty ? "Track \(id)" : title, isSelected: string(base + "/selected") == "yes")
            if type == "audio" { audio.append(track) } else if type == "sub" { subs.append(track) }
        }
        audioTracks = audio
        subtitleTracks = subs
    }
}

/// CAMetalLayer that ignores the zero/one-pixel sizes UIKit and AppKit pass during layout; MoltenVK
/// aborts on a degenerate drawable.
final class MPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set { if newValue.width > 1, newValue.height > 1 { super.drawableSize = newValue } }
    }
}

/// Hosts the engine's Metal layer and keeps its size and scale in step with the view.
#if os(macOS)
final class MPVHostView: NSView {
    let metalLayer: CAMetalLayer

    init(metalLayer: CAMetalLayer) {
        self.metalLayer = metalLayer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(metalLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        // Only the frame follows the view; the drawable keeps its fixed size (see MPVEngine.init).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = bounds
        metalLayer.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }
}

struct MPVVideoView: NSViewRepresentable {
    let engine: MPVEngine
    func makeNSView(context: Context) -> MPVHostView { MPVHostView(metalLayer: engine.metalLayer) }
    func updateNSView(_ view: MPVHostView, context: Context) {}
}
#else
final class MPVHostView: UIView {
    let metalLayer: CAMetalLayer

    init(metalLayer: CAMetalLayer) {
        self.metalLayer = metalLayer
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(metalLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Only the frame follows the view; the drawable keeps its fixed size (see MPVEngine.init).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = bounds
        metalLayer.contentsScale = window?.screen.scale ?? traitCollection.displayScale
        CATransaction.commit()
    }
}

struct MPVVideoView: UIViewRepresentable {
    let engine: MPVEngine
    func makeUIView(context: Context) -> MPVHostView { MPVHostView(metalLayer: engine.metalLayer) }
    func updateUIView(_ view: MPVHostView, context: Context) {}
}
#endif
