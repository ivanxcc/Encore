import SwiftUI
import EncoreKit

/// Households on this device. Switching is instant: the app reopens on the other household's own
/// accounts and profiles, and nothing crosses over.
struct HouseholdsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing: Household?
    @State private var creating = false

    static let symbols = ["house.fill", "building.2.fill", "tree.fill", "sun.max.fill", "moon.stars.fill",
                          "heart.fill", "star.fill", "leaf.fill", "film.fill", "gamecontroller.fill"]

    var body: some View {
        List {
            Section {
                ForEach(app.households) { household in
                    Button {
                        app.switchHousehold(to: household)
                        dismiss()
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: household.symbol)
                                .frame(width: 44, height: 44)
                                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(household.name)
                                if let caption = caption(for: household) {
                                    Text(caption).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if household.id == app.household.id {
                                Image(systemName: "checkmark").foregroundStyle(.primary)
                            }
                        }
                    }
                    .contextMenu {
                        Button("Rename", systemImage: "pencil") { editing = household }
                        if app.cloud != nil, household.id != app.homeHousehold?.id, !app.isSharedWithMe(household),
                           app.directory.settings(for: household)?.accountUserID != nil {
                            Button("Make Home Household", systemImage: "house.circle") { app.makeHome(household) }
                        }
                        if household.id != app.household.id {
                            Button(app.cloud != nil ? "Remove Household" : "Remove from This Device",
                                   systemImage: "trash", role: .destructive) {
                                app.deleteHousehold(household)
                            }
                        }
                    }
                }
            } footer: {
                Text(app.cloud != nil
                     ? "Each household keeps its own Stremio account, profiles, and watch history. Households you add here appear on every device signed in to your home household's account."
                     : "Give each person or family their own household so their Stremio account, profiles, and watch history stay completely separate.")
            }
            Section {
                Button { creating = true } label: { Label("Add Household", systemImage: "plus") }
                if app.cloud != nil {
                    NavigationLink { RedeemShareView() } label: {
                        Label("Add a Shared Household", systemImage: "person.2.badge.key.fill")
                    }
                }
            } footer: {
                if app.cloud != nil {
                    Text("Managing someone else's household? Ask them to tap Share This Household in Settings, then enter their code here.")
                }
            }
        }
        .navigationTitle("Households")
        .task { await app.syncCloud() }
        .sheet(isPresented: $creating) {
            HouseholdEditor(title: "New Household", name: "", symbol: "house.fill") { name, symbol in
                app.addHousehold(name: name, symbol: symbol)
            }
        }
        .sheet(item: $editing) { household in
            HouseholdEditor(title: "Rename", name: household.name, symbol: household.symbol) { name, symbol in
                app.renameHousehold(household, name: name, symbol: symbol)
            }
        }
    }
}

extension HouseholdsView {
    /// "Home · syncs your household list", "Shared with you", or the signed-in account.
    func caption(for household: Household) -> String? {
        if app.cloud != nil, household.id == app.homeHousehold?.id { return "Home · your households sync with this account" }
        if app.isSharedWithMe(household) { return "Shared with you" }
        if let email = app.directory.settings(for: household)?.accountEmail { return email }
        return nil
    }
}

private struct HouseholdEditor: View {
    let title: String
    @State var name: String
    @State var symbol: String
    let save: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        EditorSheet(title: title, canSave: !name.trimmingCharacters(in: .whitespaces).isEmpty,
                    save: { save(name.trimmingCharacters(in: .whitespaces), symbol); dismiss() },
                    cancel: { dismiss() }) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .semibold))
                .frame(width: 110, height: 110)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            EditorTextField(placeholder: "Household name", text: $name)
            EditorLabel("Icon")
            SymbolPicker(symbols: HouseholdsView.symbols, selection: $symbol)
        }
    }
}

/// Profiles inside the current household.
struct ProfilesView: View {
    @EnvironmentObject private var app: AppModel
    @State private var editing: Profile?

    var body: some View {
        List {
            Section {
                ForEach(app.profiles) { profile in
                    Button { editing = profile } label: {
                        HStack(spacing: 16) {
                            ProfileAvatar(profile: profile, size: 44)
                            VStack(alignment: .leading) {
                                Text(profile.name)
                                if profile.isOwner {
                                    Text("Uses the Stremio account's library").font(.caption).foregroundStyle(.secondary)
                                } else if profile.isKids {
                                    Text("Kids").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } footer: {
                Text("Every profile keeps its own Continue Watching and list. The main profile's library syncs with the household's Stremio account.")
            }
            Section {
                Button {
                    editing = Profile(name: "", avatar: "person.fill", colorIndex: app.profiles.count % Theme.Colors.avatarColors.count)
                } label: { Label("Add Profile", systemImage: "plus") }
            }
        }
        .navigationTitle("Profiles")
        .sheet(item: $editing) { profile in
            ProfileEditor(profile: profile, isNew: !app.profiles.contains { $0.id == profile.id })
        }
    }
}

private struct ProfileEditor: View {
    @State var profile: Profile
    let isNew: Bool
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var confirmDelete = false

    private let avatars = ["person.fill", "star.fill", "heart.fill", "bolt.fill", "pawprint.fill",
                           "gamecontroller.fill", "film.fill", "music.note", "leaf.fill", "sparkles"]

    private var pinIsValid: Bool { pin.isEmpty || pin.filter(\.isNumber).count == 4 }
    private var canSave: Bool { !profile.name.trimmingCharacters(in: .whitespaces).isEmpty && pinIsValid }

    var body: some View {
        EditorSheet(title: isNew ? "New Profile" : "Edit Profile", canSave: canSave, save: save, cancel: { dismiss() }) {
            ProfileAvatar(profile: profile, size: 110)
                .animation(Theme.Motion.focus, value: profile.avatar)
                .animation(Theme.Motion.focus, value: profile.colorIndex)
            EditorTextField(placeholder: "Name", text: $profile.name)

            EditorLabel("Avatar")
            SymbolPicker(symbols: avatars, selection: $profile.avatar)

            EditorLabel("Color")
            HStack(spacing: 14) {
                ForEach(Theme.Colors.avatarColors.indices, id: \.self) { index in
                    Button { profile.colorIndex = index } label: {
                        Circle().fill(Theme.Colors.avatarColors[index])
                            .frame(width: 34, height: 34)
                            .overlay(Circle().strokeBorder(.white, lineWidth: profile.colorIndex == index ? 3 : 0).padding(-4))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Color \(index + 1)")
                }
            }

            VStack(spacing: 0) {
                Toggle(isOn: $profile.isKids) {
                    Label("Kids profile", systemImage: "figure.and.child.holdinghands")
                }
                .padding(.vertical, 12)
                Divider().overlay(Color.white.opacity(0.1))
                HStack {
                    Label("PIN", systemImage: "lock.fill")
                    Spacer()
                    SecureField(profile.hasPin ? "Change" : "Optional", text: $pin)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 140)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .onChange(of: pin) { _, value in pin = String(value.filter(\.isNumber).prefix(4)) }
                    if profile.hasPin {
                        Button("Remove") { profile.pinHash = nil; pin = "" }
                            .buttonStyle(.borderless)
                    }
                }
                .padding(.vertical, 12)
            }
            .padding(.horizontal, 16)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            if !isNew && !profile.isOwner {
                Button("Delete Profile", role: .destructive) { confirmDelete = true }
                    .buttonStyle(.borderless)
                    .padding(.top, 6)
                    .confirmationDialog("Delete \(profile.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("Delete", role: .destructive) { app.deleteProfile(profile); dismiss() }
                    } message: {
                        Text("Their Continue Watching and list on this device are removed.")
                    }
            }
        }
    }

    private func save() {
        if pin.count == 4 { profile.pinHash = Profile.hashPin(pin) }
        profile.name = profile.name.trimmingCharacters(in: .whitespaces)
        app.saveProfile(profile)
        dismiss()
    }
}

// MARK: - Editor building blocks

/// A focused edit sheet: Cancel / title / Save bar, then centered content. Replaces Form-based editors,
/// where several buttons in one row behave as one big button (tapping any avatar picked the last one).
private struct EditorSheet<Content: View>: View {
    let title: String
    let canSave: Bool
    let save: () -> Void
    let cancel: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel", action: cancel).buttonStyle(.borderless)
                Spacer()
                Text(title).font(.headline)
                Spacer()
                Button("Save", action: save).buttonStyle(.borderless).fontWeight(.semibold).disabled(!canSave)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider().overlay(Color.white.opacity(0.08))
            ScrollView {
                VStack(spacing: 18) { content }
                    .padding(24)
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
            }
        }
        .encoreCanvas()
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 560)
        #endif
        #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
    }
}

private struct EditorTextField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .font(.title3.weight(.semibold))
            .multilineTextAlignment(.center)
            .textFieldStyle(.plain)
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct EditorLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.Colors.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
    }
}

/// A grid of SF Symbols where each tile is its own button with its own hit area.
private struct SymbolPicker: View {
    let symbols: [String]
    @Binding var selection: String

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 56, maximum: 72), spacing: 12)], spacing: 12) {
            ForEach(symbols, id: \.self) { symbol in
                Button { selection = symbol } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 22, weight: .semibold))
                        .frame(width: 56, height: 56)
                        .foregroundStyle(symbol == selection ? Color.black : Color.white)
                        .background(symbol == selection ? Color.white : Color.white.opacity(0.1),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(symbol)
                .accessibilityAddTraits(symbol == selection ? .isSelected : [])
            }
        }
    }
}
