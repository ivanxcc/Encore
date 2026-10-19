import SwiftUI
import ImageIO

/// Downsampling image pipeline. Posters and backdrops are decoded at the size they are displayed, off
/// the main thread, and kept in memory; that, not animation tweaks, is what makes long shelves scroll
/// smoothly on an Apple TV. Raw bytes ride URLCache, so a relaunch does not refetch.
actor ImagePipeline {
    static let shared = ImagePipeline()

    nonisolated(unsafe) private let memory = NSCache<NSString, CGImageBox>()   // NSCache is thread-safe
    private var inFlight: [String: Task<CGImage?, Never>] = [:]
    private let session: URLSession

    final class CGImageBox { let image: CGImage; init(_ image: CGImage) { self.image = image } }

    init() {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 512 << 20, directory: nil)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration: config)
        memory.totalCostLimit = 192 << 20
    }

    nonisolated func cached(_ url: URL, maxPixel: Int) -> CGImage? {
        memory.object(forKey: Self.key(url, maxPixel) as NSString)?.image
    }

    func image(_ url: URL, maxPixel: Int) async -> CGImage? {
        let key = Self.key(url, maxPixel)
        if let hit = memory.object(forKey: key as NSString) { return hit.image }
        if let running = inFlight[key] { return await running.value }
        let session = self.session
        let task = Task<CGImage?, Never>.detached(priority: .userInitiated) {
            guard let (data, _) = try? await session.data(from: url) else { return nil }
            return Self.downsample(data, maxPixel: maxPixel)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { memory.setObject(CGImageBox(image), forKey: key as NSString, cost: image.bytesPerRow * image.height) }
        return image
    }

    private static func key(_ url: URL, _ maxPixel: Int) -> String { "\(maxPixel)|\(url.absoluteString)" }

    private static func downsample(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Decode sizes shared by every full-screen use of a title's artwork (the Home hero, the title page), so
/// moving from one to the other reuses the decoded image instead of fetching and fading it in again.
enum HeroArtwork {
    #if os(tvOS)
    static let maxPixel = 3840   // Apple TV 4K
    static let logoPixel = 1400
    #elseif os(macOS)
    static let maxPixel = 3200
    static let logoPixel = 900
    #else
    static let maxPixel = 2800
    static let logoPixel = 900
    #endif
}

/// An image that dissolves in once decoded, over a quiet placeholder. An image already in memory is on
/// screen from the first frame (no flash of placeholder), and when the URL changes the old picture
/// cross-dissolves into the new one instead of blinking out. Never shows a spinner: empty space that
/// fills in reads as fast; spinners read as slow.
struct Artwork: View {
    let url: URL?
    var maxPixel: Int = 600
    var contentMode: ContentMode = .fill
    var fade: Double = 0.4

    private struct Shown: Equatable {
        let url: URL
        let image: CGImage
        static func == (a: Shown, b: Shown) -> Bool { a.url == b.url }
    }

    @State private var shown: Shown?

    init(url: URL?, maxPixel: Int = 600, contentMode: ContentMode = .fill, fade: Double = 0.4) {
        self.url = url; self.maxPixel = maxPixel; self.contentMode = contentMode; self.fade = fade
        let cached = url.flatMap { u in ImagePipeline.shared.cached(u, maxPixel: maxPixel).map { Shown(url: u, image: $0) } }
        _shown = State(initialValue: cached)
    }

    var body: some View {
        ZStack {
            Theme.Colors.placeholder.opacity(shown == nil ? 1 : 0)
            if let shown {
                Image(decorative: shown.image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .id(shown.url)
                    .transition(.opacity)
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { shown = nil; return }
        if shown?.url == url { return }
        if let hit = ImagePipeline.shared.cached(url, maxPixel: maxPixel) {
            withAnimation(.easeInOut(duration: fade)) { shown = Shown(url: url, image: hit) }
            return
        }
        guard let loaded = await ImagePipeline.shared.image(url, maxPixel: maxPixel), !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: fade)) { shown = Shown(url: url, image: loaded) }
    }
}
