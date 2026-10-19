import SwiftUI
import EncoreKit

/// Home's content: a featured hero and one shelf per add-on catalog. Each shelf loads on its own, so
/// one slow add-on never holds up the screen, and results are kept while the household stays open.
@MainActor
final class HomeModel: ObservableObject {
    struct ShelfState: Identifiable {
        let ref: CatalogRef
        var items: [MetaPreview]?
        var failed = false
        var id: String { ref.id }
    }

    @Published private(set) var shelves: [ShelfState] = []
    @Published private(set) var featured: [MetaPreview] = []

    private var loadedFor: [String] = []
    private var tasks: [Task<Void, Never>] = []

    func load(using app: AppModel) {
        let refs = AddonService.homeCatalogs(from: app.settings.addons)
        let signature = refs.map(\.id) + [app.household.id.uuidString]
        guard signature != loadedFor else { return }
        loadedFor = signature
        tasks.forEach { $0.cancel() }
        tasks = []
        shelves = refs.map { ShelfState(ref: $0) }
        featured = []
        trending = nil
        inProgress = app.continueWatching().map { $0.item.preview }
        seed = FeaturedPicker.dailySeed(profile: app.activeProfile?.id)
        if let cloud = app.cloud {
            tasks.append(Task { [weak self] in
                let titles = await cloud.trending()
                guard !Task.isCancelled, let self else { return }
                self.trending = titles.map(\.preview)
                self.pickFeaturedIfNeeded()
            })
            // Trending is a nice-to-have: after a moment the hero goes ahead with the catalogs alone.
            tasks.append(Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self, self.trending == nil else { return }
                self.trending = []
                self.pickFeaturedIfNeeded()
            })
        } else {
            trending = []
        }
        let service = app.session.addonService
        tasks += refs.enumerated().map { index, ref in
            Task { [weak self] in
                let items = try? await service.catalog(ref)
                guard !Task.isCancelled, let self, index < self.shelves.count, self.shelves[index].ref.id == ref.id else { return }
                withAnimation(Theme.Motion.content) {
                    self.shelves[index].items = items ?? []
                    self.shelves[index].failed = items == nil
                }
                self.pickFeaturedIfNeeded()
            }
        }
    }

    func reload(using app: AppModel) {
        loadedFor = []
        load(using: app)
    }

    private var trending: [MetaPreview]?
    private var inProgress: [MetaPreview] = []
    private var seed = ""

    /// The hero is curated (see FeaturedPicker): shows in progress, what is trending this week (from
    /// Encore Cloud) or else the top of the catalogs, alternating movies and shows, reshuffled daily.
    /// It is chosen once trending has answered (or timed out) and the first two catalogs have loaded.
    private func pickFeaturedIfNeeded() {
        guard featured.isEmpty, let trending else { return }
        let loaded = shelves.prefix(2).allSatisfy { $0.items != nil }
        let pool = shelves.compactMap(\.items).filter { !$0.isEmpty }
        guard loaded || !trending.isEmpty, !(pool.isEmpty && trending.isEmpty) else { return }
        let picked = FeaturedPicker.pick(inProgress: inProgress, trending: trending, catalogs: pool, seed: seed)
        guard !picked.isEmpty else { return }
        withAnimation(Theme.Motion.content) { featured = picked }
        // Warm the hero's artwork so every crossfade lands on a decoded image.
        Task.detached(priority: .utility) {
            for item in picked {
                if let url = item.backdropURL { _ = await ImagePipeline.shared.image(url, maxPixel: HeroArtwork.maxPixel) }
                if let url = item.logoURL { _ = await ImagePipeline.shared.image(url, maxPixel: HeroArtwork.logoPixel) }
            }
        }
    }
}
