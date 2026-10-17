import Foundation
import SwiftUI
import QuartzCore
import Metal
import Libmpv
import MarqueeKit
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

    /// The mpv handle is used from mpv's own event queue, so it is not actor-isolated.
    nonisolated(unsafe) private var handle: OpaquePointer?
    private let eventQueue = DispatchQueue(label: "marquee.mpv.events", qos: .userInitiated)
    private var started = false
    private var pendingSubtitles: [Subtitle] = []
    private var retainedSelf: Unmanaged<MPVEngine>?

    init() {
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.framebufferOnly = true
        create()
    }

    private func create() {
        guard let mpv = mpv_create() else { return }
        handle = mpv
        var layer = metalLayer
        mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &layer)
        let options: [(String, String)] = [
            ("vo", "gpu-next"),
            ("gpu-api", "vulkan"),
            ("gpu-context", "moltenvk"),
            ("hwdec", "videotoolbox"),
            ("target-colorspace-hint", "yes"),
            ("video-sync", "display-resample"),
            ("cache", "yes"),
            ("demuxer-max-bytes", "300MiB"),
            ("demuxer-max-back-bytes", "100MiB"),
            ("demuxer-readahead-secs", "30"),
            ("network-timeout", "25"),
            ("keep-open", "no"),
            ("idle", "yes"),
            ("ytdl", "no"),
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("terminal", "no"),
            ("msg-level", "all=warn"),
            ("sub-auto", "fuzzy"),
            ("slang", Self.preferredLanguages),
            ("alang", Self.preferredLanguages),
            ("subs-fallback", "default"),
            ("user-agent", "Marquee/1.0"),
        ]
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

        // The callback fires on an mpv thread. It holds a retained reference released in stop(), so it
        // can never outlive the engine.
        let retained = Unmanaged.passRetained(self)
        retainedSelf = retained
        mpv_set_wakeup_callback(mpv, { context in
            guard let context else { return }
            Unmanaged<MPVEngine>.fromOpaque(context).takeUnretainedValue().wakeUp()
        }, retained.toOpaque())
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
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = bounds
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
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
        let scale = window?.screen.scale ?? traitCollection.displayScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = bounds
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        CATransaction.commit()
    }
}

struct MPVVideoView: UIViewRepresentable {
    let engine: MPVEngine
    func makeUIView(context: Context) -> MPVHostView { MPVHostView(metalLayer: engine.metalLayer) }
    func updateUIView(_ view: MPVHostView, context: Context) {}
}
#endif
