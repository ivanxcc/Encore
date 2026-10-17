import SwiftUI
import MarqueeKit

/// Search across every add-on catalog that supports it, debounced as you type.
struct SearchView: View {
    @EnvironmentObject private var app: AppModel
    @State private var query = ""
    @State private var results: [(CatalogRef, [MetaPreview])] = []
    @State private var searching = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: Theme.Metrics.shelfSpacing) {
                if results.isEmpty && !searching {
                    ContentUnavailableView(query.isEmpty ? "Search" : "No Results",
                                           systemImage: "magnifyingglass",
                                           description: Text(query.isEmpty ? "Find movies and shows across your add-ons." : "Try a different title."))
                        .padding(.top, 80)
                        .frame(maxWidth: .infinity)
                }
                ForEach(results, id: \.0.id) { ref, metas in
                    Shelf(title: ref.title, items: metas) { meta in
                        NavigationLink(value: Route.title(meta)) { PosterCardLabel(meta: meta) }
                            .cardLinkStyle()
                    }
                }
            }
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
        .searchable(text: $query, prompt: "Movies, Shows, and More")
        .task(id: query) {
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 2 else { results = []; return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            searching = true
            let found = await app.session.addonService.search(trimmed, in: app.settings.addons)
            guard !Task.isCancelled else { return }
            withAnimation(Theme.Motion.content) { results = found }
            searching = false
        }
        .navigationTitle("Search")
    }
}
