import SwiftUI
import EncoreKit

/// Settings › Encore Cloud: keeps this household's profiles, their history, and settings the same on
/// every device signed in to its Stremio account. Hidden in builds released without a cloud.
struct CloudSection: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        if app.cloud != nil, app.settings.accountEmail != nil {
            Section {
                LabeledContent {
                    status
                } label: {
                    Label("Sync", systemImage: "icloud.fill")
                }
                NavigationLink { ShareHouseholdView() } label: {
                    Label("Share This Household", systemImage: "person.badge.plus")
                }
                #if !os(tvOS)
                NavigationLink { ApproveTVView() } label: {
                    Label("Sign In an Apple TV", systemImage: "appletv.fill")
                }
                #endif
            } header: {
                Text("Encore Cloud")
            } footer: {
                Text("Profiles, their watch history and My List, and playback settings sync to every device signed in to this household's Stremio account.")
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch app.cloudStatus {
        case .off: Text("Off")
        case .syncing: ProgressView()
        case let .synced(date): Text("Up to date · \(date.formatted(date: .omitted, time: .shortened))")
        case let .failed(message): Text(message).foregroundStyle(.orange).multilineTextAlignment(.trailing)
        }
    }
}

/// A short code, big and readable from the couch: "ABCD-EFGH".
struct CodeDisplay: View {
    let code: String

    var body: some View {
        Text(code)
            .font(.system(size: size, weight: .bold, design: .rounded).monospaced())
            .kerning(size * 0.12)
            .padding(.vertical, size * 0.35)
            .padding(.horizontal, size * 0.6)
            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: size * 0.4, style: .continuous))
            #if !os(tvOS)
            .textSelection(.enabled)
            #endif
            .accessibilityLabel(code.map(String.init).joined(separator: " "))
    }

    private var size: CGFloat {
        #if os(tvOS)
        return 76
        #else
        return 40
        #endif
    }
}

/// The owner shares their household: a one-time code someone else enters in Settings › Households.
struct ShareHouseholdView: View {
    @EnvironmentObject private var app: AppModel
    @State private var code: CloudClient.Code?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "person.2.badge.key.fill")
                .font(.system(size: 54)).foregroundStyle(.tint)
            Text("Share \(app.household.name)")
                .font(.title.weight(.bold))
            Text("On the other person's device, open Settings › Households › Add a Shared Household and enter this code. \(app.household.name) appears there with all of its profiles, and stays in sync. Their own household is not touched.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 560)
            if let code {
                CodeDisplay(code: code.code)
                Text("Works once, until \(code.expiry.formatted(date: .omitted, time: .shortened)).")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Button("Try Again") { Task { await make() } }.pillButtonStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Share Household")
        .task { await make() }
    }

    private func make() async {
        error = nil
        do { code = try await app.createShareCode() }
        catch { self.error = (error as? LocalizedError)?.errorDescription ?? "Couldn't reach Encore Cloud." }
    }
}

/// Enter a code: from a household being shared with you, or from an Apple TV waiting to sign in.
struct CodeEntryView: View {
    let title: String
    let message: String
    let action: String
    let submit: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var working = false
    @State private var error: String?
    @State private var done = false

    var body: some View {
        Form {
            Section {
                TextField("ABCD-EFGH", text: $code)
                    .font(.title2.monospaced())
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
                    .onChange(of: code) { _, value in code = Self.format(value) }
            } footer: {
                Text(message)
            }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            Section {
                Button {
                    working = true
                    error = nil
                    Task {
                        do {
                            try await submit(code)
                            done = true
                            try? await Task.sleep(for: .seconds(1))
                            dismiss()
                        } catch CloudClient.CloudError.expired {
                            error = "That code is invalid or has expired. Ask for a new one."
                        } catch {
                            self.error = (error as? LocalizedError)?.errorDescription ?? "Couldn't reach Encore Cloud."
                        }
                        working = false
                    }
                } label: {
                    if done { Label("Done", systemImage: "checkmark.circle.fill") }
                    else if working { ProgressView() }
                    else { Text(action) }
                }
                .disabled(code.filter(\.isLetter).count + code.filter(\.isNumber).count < 8 || working || done)
            }
        }
        .navigationTitle(title)
        #if os(macOS)
        .formStyle(.grouped)
        #endif
    }

    /// Uppercase, drop anything that isn't a letter or digit, and add the dash: "abcdefgh" -> "ABCD-EFGH".
    static func format(_ raw: String) -> String {
        let clean = String(raw.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(8))
        return clean.count > 4 ? String(clean.prefix(4)) + "-" + String(clean.dropFirst(4)) : clean
    }
}

struct RedeemShareView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        CodeEntryView(
            title: "Add a Shared Household",
            message: "Enter the code from Settings › Encore Cloud › Share This Household on the owner's device. Their household is added here, signed in and with all of its profiles; yours stays exactly as it is.",
            action: "Add Household") { code in
            _ = try await app.addSharedHousehold(code: code)
        }
    }
}

#if !os(tvOS)
struct ApproveTVView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        CodeEntryView(
            title: "Sign In an Apple TV",
            message: "On the Apple TV, open Encore › Settings › Sign In. Enter the code it shows. The TV signs in to \(app.household.name) with all of its profiles.",
            action: "Sign In TV") { code in
            try await app.approveTV(code: code)
        }
    }
}
#endif

/// On the Apple TV: show a code, sign in when a phone approves it. No typing a password with a remote.
struct TVPairingPanel: View {
    @EnvironmentObject private var app: AppModel
    let onSignedIn: () -> Void
    @State private var code: CloudClient.Code?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 22) {
            Text("Sign in with your iPhone or Mac").font(.title3.weight(.semibold))
            Text("In Encore on a device that's already signed in, go to Settings › Encore Cloud › Sign In an Apple TV and enter:")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 900)
            if let code {
                CodeDisplay(code: code.code)
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity)
        .task { await run() }
    }

    private func run() async {
        guard let cloud = app.cloud else { return }
        while !Task.isCancelled {
            do {
                let started = try await cloud.startPairing()
                code = started
                error = nil
                guard let token = started.pollToken else { return }
                while !Task.isCancelled, Date() < started.expiry {
                    try await Task.sleep(for: .seconds(2))
                    if let session = try await cloud.pollPairing(token: token) {
                        _ = try await app.signIn(with: session)
                        onSignedIn()
                        return
                    }
                }
            } catch is CancellationError {
                return
            } catch CloudClient.CloudError.expired {
                continue   // show a fresh code
            } catch {
                self.error = "Couldn't reach Encore Cloud. Retrying…"
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}
