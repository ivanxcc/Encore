import SwiftUI
import EncoreKit

/// The active profile's list: Continue Watching, then everything saved, split into movies and shows.
struct LibraryView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        let _ = app.libraryRevision
        let items = app.myList()
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: Theme.Metrics.shelfSpacing) {
                ContinueWatchingShelf()
                let movies = items.filter { $0.type == "movie" }
                let shows = items.filter { $0.type == "series" }
                let other = items.filter { $0.type != "movie" && $0.type != "series" }
                shelf("Movies", movies)
                shelf("Shows", shows)
                shelf("Other", other)
                if items.isEmpty {
                    ContentUnavailableView("Your List Is Empty", systemImage: "plus.circle",
                                           description: Text("Add movies and shows with the + button and they'll appear here."))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                }
            }
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
        .navigationTitle("Library")
    }

    @ViewBuilder
    private func shelf(_ title: String, _ items: [StremioLibraryItem]) -> some View {
        if !items.isEmpty {
            Shelf(title: title, items: items) { item in
                NavigationLink(value: Route.title(item.preview)) { PosterCardLabel(meta: item.preview) }
                    .cardLinkStyle()
                    .contextMenu {
                        Button("Remove from My List", systemImage: "minus.circle") { app.setInList(item.preview, false) }
                    }
            }
        }
    }
}
