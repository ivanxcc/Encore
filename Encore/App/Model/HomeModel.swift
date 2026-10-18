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
        shelves = refs.map { ShelfState(ref: $0) }
        featured = []
        let service = app.session.addonService
        tasks = refs.enumerated().map { index, ref in
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

    /// The hero rotates through the first loaded catalog's titles that have a backdrop.
    private func pickFeaturedIfNeeded() {
        guard featured.isEmpty,
              let first = shelves.first(where: { !($0.items ?? []).isEmpty })?.items else { return }
        let withArt = first.filter { $0.background != nil }
        withAnimation(Theme.Motion.content) { featured = Array((withArt.isEmpty ? first : withArt).prefix(6)) }
    }
}
