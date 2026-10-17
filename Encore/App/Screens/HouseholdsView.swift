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
                            Text(household.name)
                            Spacer()
                            if household.id == app.household.id {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                    .contextMenu {
                        Button("Rename", systemImage: "pencil") { editing = household }
                        if household.id != app.household.id {
                            Button("Remove from This Device", systemImage: "trash", role: .destructive) {
                                app.deleteHousehold(household)
                            }
                        }
                    }
                }
            } footer: {
                Text("Give each person or family their own household so their Stremio account, profiles, and watch history stay completely separate.")
            }
            Section {
                Button { creating = true } label: { Label("Add Household", systemImage: "plus") }
            }
        }
        .navigationTitle("Households")
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

private struct HouseholdEditor: View {
    let title: String
    @State var name: String
    @State var symbol: String
    let save: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 14) {
                        ForEach(HouseholdsView.symbols, id: \.self) { candidate in
                            Button { symbol = candidate } label: {
                                Image(systemName: candidate)
                                    .frame(width: 54, height: 54)
                                    .background(candidate == symbol ? Color.white : Color.white.opacity(0.1),
                                                in: RoundedRectangle(cornerRadius: 12))
                                    .foregroundStyle(candidate == symbol ? Color.black : Color.white)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(name.trimmingCharacters(in: .whitespaces), symbol)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 380)
        #endif
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

    private let avatars = ["person.fill", "star.fill", "heart.fill", "bolt.fill", "pawprint.fill", "gamecontroller.fill", "film.fill", "music.note"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack { Spacer(); ProfileAvatar(profile: profile, size: 96); Spacer() }
                    TextField("Name", text: $profile.name)
                }
                Section("Avatar") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 14) {
                        ForEach(avatars, id: \.self) { symbol in
                            Button { profile.avatar = symbol } label: {
                                Image(systemName: symbol).frame(width: 50, height: 50)
                                    .background(profile.avatar == symbol ? Color.white.opacity(0.3) : Color.clear, in: Circle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 14) {
                        ForEach(Theme.Colors.avatarColors.indices, id: \.self) { index in
                            Button { profile.colorIndex = index } label: {
                                Circle().fill(Theme.Colors.avatarColors[index])
                                    .frame(width: 36, height: 36)
                                    .overlay(Circle().strokeBorder(.white, lineWidth: profile.colorIndex == index ? 3 : 0))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Section {
                    Toggle("Kids Profile", isOn: $profile.isKids)
                    SecureField(profile.hasPin ? "Change 4-digit PIN" : "4-digit PIN (optional)", text: $pin)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    if profile.hasPin {
                        Button("Remove PIN") { profile.pinHash = nil }
                    }
                }
                if !isNew && !profile.isOwner {
                    Section {
                        Button("Delete Profile", role: .destructive) {
                            app.deleteProfile(profile)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "New Profile" : "Edit Profile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let digits = pin.filter(\.isNumber)
                        if digits.count == 4 { profile.pinHash = Profile.hashPin(digits, profileID: profile.id) }
                        profile.name = profile.name.trimmingCharacters(in: .whitespaces)
                        app.saveProfile(profile)
                        dismiss()
                    }
                    .disabled(profile.name.trimmingCharacters(in: .whitespaces).isEmpty || (!pin.isEmpty && pin.filter(\.isNumber).count != 4))
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 520)
        #endif
    }
}
