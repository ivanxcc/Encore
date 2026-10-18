import SwiftUI
import EncoreKit

/// Settings, grouped the way the Apple TV Settings app groups things: who you are first, then where
/// content comes from, then how it plays.
struct SettingsView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        Form {
            Section {
                NavigationLink { HouseholdsView() } label: {
                    LabeledContent {
                        Text(app.household.name)
                    } label: {
                        Label("Household", systemImage: app.household.symbol)
                    }
                }
                NavigationLink { ProfilesView() } label: {
                    LabeledContent {
                        Text(app.activeProfile?.name ?? "")
                    } label: {
                        Label("Profiles", systemImage: "person.2.fill")
                    }
                }
                Button {
                    app.activeProfile = nil
                } label: {
                    Label("Switch Profile", systemImage: "arrow.left.arrow.right")
                }
            } header: {
                Text("Household")
            } footer: {
                Text("Each household has its own accounts, add-ons, profiles, and watch history. Nothing is shared between households.")
            }

            Section {
                if let email = app.settings.accountEmail {
                    LabeledContent("Signed in as", value: email)
                    Button("Sync Now") { Task { await app.refresh() } }
                    Button("Sign Out", role: .destructive) { Task { await app.signOut() } }
                } else {
                    NavigationLink { SignInView() } label: {
                        Label(app.settings.ownerEmail.map { "Sign In as \($0)" } ?? "Sign In to Stremio",
                              systemImage: "person.crop.circle.badge.plus")
                    }
                    if app.settings.ownerEmail != nil {
                        Button("Release Household from This Account", role: .destructive) { app.releaseHouseholdFromAccount() }
                    }
                }
            } header: {
                Text("Stremio Account")
            } footer: {
                Text("A household belongs to the first Stremio account that signs in to it. Signing in with another account opens that account's own household, so two people's libraries and history never mix.")
            }

            Section {
                NavigationLink { AddonsView() } label: {
                    LabeledContent {
                        Text("\(app.settings.addons.count)")
                    } label: {
                        Label("Add-ons", systemImage: "puzzlepiece.extension.fill")
                    }
                }
                NavigationLink { StreamingServerView() } label: {
                    LabeledContent {
                        Text(app.settings.streamingServer?.host() ?? "Off")
                    } label: {
                        Label("Streaming Server", systemImage: "server.rack")
                    }
                }
            } header: {
                Text("Sources")
            } footer: {
                Text("Add-ons provide catalogs and sources. A streaming server is only needed to play torrents.")
            }

            Section("Playback") {
                Picker("Maximum Quality", selection: Binding(
                    get: { app.settings.preferences.maxResolution },
                    set: { value in app.updateSettings { $0.preferences.maxResolution = value } })) {
                    Text("4K").tag(StreamTraits.Resolution.uhd4k.rawValue)
                    Text("1080p").tag(StreamTraits.Resolution.hd1080.rawValue)
                    Text("720p").tag(StreamTraits.Resolution.hd720.rawValue)
                }
                Toggle("Prefer HDR", isOn: Binding(
                    get: { app.settings.preferences.preferHDR },
                    set: { value in app.updateSettings { $0.preferences.preferHDR = value } }))
                Toggle("Hide Cam Releases", isOn: Binding(
                    get: { app.settings.preferences.hideCam },
                    set: { value in app.updateSettings { $0.preferences.hideCam = value } }))
                Toggle("Allow Torrents", isOn: Binding(
                    get: { app.settings.preferences.allowTorrents },
                    set: { value in app.updateSettings { $0.preferences.allowTorrents = value } }))
            }

            VideoAudioSection()

            Section("About") {
                LabeledContent("Version", value: versionText)
                #if os(macOS)
                MacUpdateRow()
                #endif
            }
        }
        .navigationTitle("Settings")
        #if os(macOS)
        .formStyle(.grouped)
        #endif
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return "\(version) (\(build))"
    }
}

#if os(macOS)
private struct MacUpdateRow: View {
    @ObservedObject private var updater = MacUpdater.shared
    @State private var checking = false

    var body: some View {
        HStack {
            Button(checking ? "Checking…" : "Check for Updates") {
                checking = true
                Task { await updater.check(userInitiated: true); checking = false }
            }
            .disabled(checking)
            Spacer()
            if updater.state == .upToDate { Text("Encore is up to date").foregroundStyle(.secondary) }
        }
    }
}
#endif

struct SignInView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("Email", text: $email)
                    .textContentType(.username)
                    #if os(iOS)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
            } footer: {
                Text("Your library, add-ons, and progress come with your Stremio account. If this account already has a household on this device, or \(app.household.name) belongs to someone else, Encore opens the account's own household.")
            }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
            Section {
                Button {
                    working = true
                    error = nil
                    Task {
                        do {
                            try await app.signIn(email: email, password: password)
                            dismiss()
                        } catch let apiError as StremioAPI.APIError {
                            if case let .server(message) = apiError { error = message } else { error = "Sign in failed." }
                        } catch {
                            self.error = "Couldn't reach Stremio. Check your connection and try again."
                        }
                        working = false
                    }
                } label: {
                    if working { ProgressView() } else { Text("Sign In") }
                }
                .disabled(email.isEmpty || password.isEmpty || working)
            }
        }
        .navigationTitle("Sign In")
        #if os(macOS)
        .formStyle(.grouped)
        #endif
    }
}

struct AddonsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var installURL = ""
    @State private var installing = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                TextField("Add-on URL (https://…/manifest.json)", text: $installURL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                Button {
                    installing = true
                    error = nil
                    Task {
                        do {
                            try await app.installAddon(installURL)
                            installURL = ""
                        } catch {
                            self.error = "That doesn't look like a working add-on URL."
                        }
                        installing = false
                    }
                } label: {
                    if installing { ProgressView() } else { Label("Install", systemImage: "plus.circle.fill") }
                }
                .disabled(installURL.isEmpty || installing)
                if let error { Text(error).foregroundStyle(.red) }
            } footer: {
                Text("Paste the add-on's install link. Add-ons install to this household and to its Stremio account when signed in.")
            }

            Section("Installed") {
                ForEach(app.settings.addons) { addon in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(addon.manifest.name).font(.headline)
                        Text(addon.manifest.description ?? addon.baseURL.host() ?? "")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .contextMenu {
                        if !addon.isProtected {
                            Button("Remove", role: .destructive) { Task { await app.removeAddon(addon) } }
                        }
                    }
                }
                #if !os(tvOS)
                .onMove { source, destination in Task { await app.moveAddons(from: source, to: destination) } }
                .onDelete { offsets in
                    let targets = offsets.map { app.settings.addons[$0] }.filter { !$0.isProtected }
                    Task { for addon in targets { await app.removeAddon(addon) } }
                }
                #endif
            }
        }
        .navigationTitle("Add-ons")
        #if os(iOS)
        .toolbar { EditButton() }
        #endif
    }
}

struct StreamingServerView: View {
    @EnvironmentObject private var app: AppModel
    @State private var address = ""

    var body: some View {
        Form {
            Section {
                TextField("http://192.168.1.10:11470", text: $address)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                Button("Save") {
                    let trimmed = address.trimmingCharacters(in: .whitespaces)
                    app.updateSettings { $0.streamingServer = trimmed.isEmpty ? nil : URL(string: trimmed) }
                }
                if app.settings.streamingServer != nil {
                    Button("Turn Off", role: .destructive) {
                        address = ""
                        app.updateSettings { $0.streamingServer = nil }
                    }
                }
            } footer: {
                Text("Run Stremio Service (or the Stremio desktop app) on a computer or NAS on your network and enter its address. Torrent sources play through it; debrid and direct links never need it.")
            }
        }
        .navigationTitle("Streaming Server")
        .onAppear { address = app.settings.streamingServer?.absoluteString ?? "" }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
    }
}

/// Picture and sound, device-wide (these describe this TV and receiver, not a household).
private struct VideoAudioSection: View {
    @AppStorage(DisplayModeMatcher.enabledKey) private var matchContent = true
    @AppStorage(AudioOutputMode.key) private var audioOutput = AudioOutputMode.auto.rawValue
    @AppStorage(VideoQuality.key) private var videoQuality = VideoQuality.balanced.rawValue

    var body: some View {
        Section {
            #if os(tvOS)
            Toggle("Match Frame Rate and Dynamic Range", isOn: $matchContent)
            #endif
            Picker("Audio Output", selection: $audioOutput) {
                ForEach(AudioOutputMode.allCases) { Text($0.label).tag($0.rawValue) }
            }
            Picker("Picture Processing", selection: $videoQuality) {
                ForEach(VideoQuality.allCases) { Text($0.label).tag($0.rawValue) }
            }
        } header: {
            Text("Video and Audio")
        } footer: {
            Text(footer)
        }
    }

    private var footer: String {
        #if os(tvOS)
        let system = DisplayModeMatcher.isEnabledInSystemSettings
            ? "Match Content is on in tvOS Settings."
            : "Also turn on Settings › Video and Audio › Match Content › Match Dynamic Range and Match Frame Rate on your Apple TV; tvOS ignores the request otherwise."
        return "Plays each title at its own frame rate and in Dolby Vision, HDR10, or HLG. " + system
            + " Lossless TrueHD and DTS-HD are decoded to uncompressed multichannel PCM; Dolby Atmos in Dolby Digital Plus is passed through. High Quality scaling suits Apple TV 4K (2022)."
        #else
        return "Lossless TrueHD and DTS-HD are decoded to uncompressed multichannel PCM. HDR plays in HDR on screens that support it and is tone mapped elsewhere."
        #endif
    }
}
