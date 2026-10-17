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

/// An image that fades in once decoded, over a quiet placeholder. Never shows a spinner: empty space
/// that fills in reads as fast; spinners read as slow.
struct Artwork: View {
    let url: URL?
    var maxPixel: Int = 600
    var contentMode: ContentMode = .fill

    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Theme.Colors.placeholder
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { image = nil; return }
        if let hit = ImagePipeline.shared.cached(url, maxPixel: maxPixel) { image = hit; return }
        let loaded = await ImagePipeline.shared.image(url, maxPixel: maxPixel)
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.25)) { image = loaded }
    }
}
