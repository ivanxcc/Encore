import SwiftUI
import EncoreKit

/// Settings › Home Screen: the active profile's row order. Continue Watching stays first; every other
/// row can be moved or hidden. Saved on the profile, so it syncs with the profile to every device.
struct HomeLayoutView: View {
    @EnvironmentObject private var app: AppModel
    @State private var rows: [Row] = []

    struct Row: Identifiable, Equatable {
        let ref: CatalogRef
        var shown: Bool
        var id: String { ref.id }
        static func == (a: Row, b: Row) -> Bool { a.id == b.id && a.shown == b.shown }
    }

    var body: some View {
        List {
            Section {
                Label("Continue Watching", systemImage: "play.circle")
                    .foregroundStyle(.secondary)
            } footer: {
                Text("Always first.")
            }
            Section {
                ForEach($rows) { $row in
                    rowView($row)
                }
                #if !os(tvOS)
                .onMove { from, to in
                    rows.move(fromOffsets: from, toOffset: to)
                    save()
                }
                #endif
            } header: {
                Text("Rows")
            } footer: {
                #if os(tvOS)
                Text("Select a row to show or hide it. Hold a row to move it.")
                #else
                Text("Drag to reorder. Turn a row off to hide it. Applies to \(app.activeProfile?.name ?? "this profile") on every device.")
                #endif
            }
            Section {
                Button("Reset to Add-on Order", role: .destructive) {
                    updateProfile { $0.homeLayout = nil }
                    load()
                }
            }
        }
        .navigationTitle("Home Screen")
        #if os(iOS)
        .environment(\.editMode, .constant(.active))
        #endif
        .onAppear(perform: load)
    }

    @ViewBuilder
    private func rowView(_ row: Binding<Row>) -> some View {
        #if os(tvOS)
        Button {
            row.wrappedValue.shown.toggle()
            save()
        } label: {
            HStack {
                Text(row.wrappedValue.ref.title)
                Spacer()
                Image(systemName: row.wrappedValue.shown ? "eye" : "eye.slash")
            }
        }
        .contextMenu {
            Button("Move Up", systemImage: "arrow.up") { move(row.wrappedValue, by: -1) }
            Button("Move Down", systemImage: "arrow.down") { move(row.wrappedValue, by: 1) }
        }
        #else
        Toggle(row.wrappedValue.ref.title, isOn: Binding(
            get: { row.wrappedValue.shown },
            set: { row.wrappedValue.shown = $0; save() }))
        #endif
    }

    private func load() {
        let available = AddonService.homeCatalogs(from: app.settings.addons)
        let layout = app.activeProfile?.homeLayout ?? HomeLayout()
        rows = layout.rows(available).map { Row(ref: $0.ref, shown: $0.shown) }
    }

    private func move(_ row: Row, by delta: Int) {
        guard let index = rows.firstIndex(of: row) else { return }
        let target = min(max(0, index + delta), rows.count - 1)
        guard target != index else { return }
        withAnimation(Theme.Motion.content) { rows.swapAt(index, target) }
        save()
    }

    private func save() {
        let layout = HomeLayout(order: rows.map(\.id), hidden: rows.filter { !$0.shown }.map(\.id))
        updateProfile { $0.homeLayout = layout }
    }

    private func updateProfile(_ change: (inout Profile) -> Void) {
        guard var profile = app.activeProfile else { return }
        change(&profile)
        app.saveProfile(profile)
    }
}
