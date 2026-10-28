import SwiftUI
import EncoreKit

/// Search across every add-on catalog that supports it, debounced as you type.
struct SearchView: View {
    /// The Mac's floating search field drives this page; elsewhere the page has its own search field.
    var externalQuery: Binding<String>?
    @EnvironmentObject private var app: AppModel
    @State private var ownQuery = ""
    @State private var results: [(CatalogRef, [MetaPreview])] = []
    @State private var searching = false
    /// This session's searches, by query.
    @MainActor private static var recent: [String: [(CatalogRef, [MetaPreview])]] = [:]

    init(query: Binding<String>? = nil) {
        externalQuery = query
    }

    private var query: String { externalQuery?.wrappedValue ?? ownQuery }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: Theme.Metrics.shelfSpacing) {
                if results.isEmpty && !searching && showsEmptyState {
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
                            .titleMenu(meta)
                    }
                }
            }
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
        .modifier(OwnSearchField(enabled: externalQuery == nil, text: $ownQuery))
        .task(id: query) {
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 2 else { results = []; searching = false; return }
            // A search already made this session (typing back over it) is instant.
            if let hit = Self.recent[trimmed.lowercased()] { results = hit; searching = false; return }
            // Just long enough not to search for every letter of a word typed quickly.
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            searching = true
            // Results appear as each add-on answers, rather than after the slowest one.
            let found = await app.session.addonService.search(trimmed, in: app.settings.addons) { partial in
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    withAnimation(Theme.Motion.content) { results = partial }
                }
            }
            guard !Task.isCancelled else { return }
            Self.recent[trimmed.lowercased()] = found
            withAnimation(Theme.Motion.content) { results = found }
            searching = false
        }
        #if !os(tvOS)
        // tvOS draws its own search field and keyboard at the top; a title there sits under the letters.
        .pageTitle("Search")
        #endif
    }

    /// On tvOS the keyboard is the empty state; only "No Results" is worth saying there.
    private var showsEmptyState: Bool {
        #if os(tvOS)
        return query.trimmingCharacters(in: .whitespaces).count >= 2
        #else
        return true
        #endif
    }
}

/// The system search field, for every platform but the Mac (which has a floating one).
private struct OwnSearchField: ViewModifier {
    let enabled: Bool
    @Binding var text: String

    func body(content: Content) -> some View {
        if enabled {
            #if os(iOS)
            // Always showing on the Search tab, not hidden until the page is pulled down.
            content.searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always),
                               prompt: "Movies, Shows, and More")
            #else
            content.searchable(text: $text, prompt: "Movies, Shows, and More")
            #endif
        } else {
            content
        }
    }
}
