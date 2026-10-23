import SwiftUI
import EncoreKit
#if os(tvOS) || os(macOS)
import CoreImage
import CoreImage.CIFilterBuiltins
#endif

/// Settings › Encore Cloud: keeps this household's profiles, their history, and settings the same on
/// every device signed in to its Stremio account. Hidden in builds released without a cloud.
struct CloudSection: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        if app.cloud == nil {
            Section {
                Label("Not included in this build", systemImage: "icloud.slash")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Encore Cloud")
            } footer: {
                Text("This copy of Encore was built without an Encore Cloud address, so profiles and households stay on this device. Install the latest build from the Releases page.")
            }
        } else if app.settings.accountEmail == nil {
            Section {
                Label("Sign in to sync", systemImage: "icloud")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Encore Cloud")
            } footer: {
                Text("Sign in to this household's Stremio account and its profiles, history, and your other households appear here.")
            }
        } else {
            Section {
                LabeledContent {
                    status
                } label: {
                    Label("Sync", systemImage: "icloud.fill")
                }
                Button {
                    Task { await app.syncNow() }
                } label: {
                    LabeledContent {
                        Text("\(app.profiles.count) profiles · \(app.households.count) households")
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(app.cloudStatus == .syncing)
                NavigationLink { ShareHouseholdView().pushedPage() } label: {
                    Label("Share This Household", systemImage: "person.badge.plus")
                }
                #if !os(tvOS)
                NavigationLink { ApproveTVView().pushedPage() } label: {
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
        .pageTitle("Share Household")
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
        .pageTitle(title)
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
/// Settings › Encore Cloud › Sign In an Apple TV: type the code a TV (or Mac) shows.
struct ApproveTVView: View {
    var body: some View { ApproveDeviceView(initialCode: nil) }
}

/// Approve a TV's or Mac's sign-in, from its QR code or a typed code. The account it joins is always
/// shown and chosen here (the home household by default), never inferred from whatever was open.
struct ApproveDeviceView: View {
    let initialCode: String?
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var accountID: UUID?
    @State private var working = false
    @State private var done = false
    @State private var error: String?

    var body: some View {
        Form {
            if initialCode == nil {
                Section {
                    TextField("ABCD-EFGH", text: $code)
                        .font(.title2.monospaced())
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                        .onChange(of: code) { _, value in code = CodeEntryView.format(value) }
                } footer: {
                    Text("On the TV, open Encore and choose Sign In. Enter the code it shows, or just scan its QR code with this iPhone's camera.")
                }
            } else {
                Section {
                    VStack(spacing: 14) {
                        Image(systemName: "appletv.fill").font(.system(size: 44)).foregroundStyle(.secondary)
                        Text("Sign in a TV?").font(.title2.weight(.bold))
                        CodeDisplay(code: code)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            }
            Section {
                ForEach(app.signInAccounts) { account in
                    Button { accountID = account.id } label: {
                        HStack(spacing: 14) {
                            Image(systemName: account.symbol).frame(width: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.name).foregroundStyle(.primary)
                                if let email = app.accountEmail(of: account) {
                                    Text(email).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if account.id == selectedID { Image(systemName: "checkmark").foregroundStyle(.primary) }
                        }
                    }
                }
            } header: {
                Text("Sign In As")
            } footer: {
                Text("The TV joins this household: its Stremio account, profiles, and watch history.")
            }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            Section {
                Button {
                    approve()
                } label: {
                    if done { Label("Signed In", systemImage: "checkmark.circle.fill") }
                    else if working { ProgressView() }
                    else { Text("Sign In TV").fontWeight(.semibold) }
                }
                .disabled(code.filter { $0.isLetter || $0.isNumber }.count < 8 || selectedID == nil || working || done)
            }
        }
        .pageTitle("Sign In a TV")
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .onAppear {
            if let initialCode { code = CodeEntryView.format(initialCode) }
            accountID = accountID ?? app.signInAccounts.first?.id
        }
    }

    private var selectedID: UUID? { accountID ?? app.signInAccounts.first?.id }

    private func approve() {
        guard let account = app.signInAccounts.first(where: { $0.id == selectedID }) else { return }
        working = true
        error = nil
        Task {
            do {
                try await app.approveDevice(code: code, as: account)
                done = true
                try? await Task.sleep(for: .seconds(1.2))
                dismiss()
            } catch CloudClient.CloudError.expired {
                error = "That code has expired. Choose Sign In on the TV again for a new one."
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "Couldn't reach Encore Cloud."
            }
            working = false
        }
    }
}
#endif

#if os(tvOS) || os(macOS)
/// Sign in on a TV (or Mac), the way streaming apps do it: scan a QR code with your phone, or type the
/// code on it, and approve there. No password typed with a remote. Email sign-in remains as a fallback.
struct DeviceSignInView: View {
    let useEmail: () -> Void
    let onSignedIn: () -> Void
    @EnvironmentObject private var app: AppModel
    @State private var code: CloudClient.Code?
    @State private var error: String?
    @State private var signedInAs: String?

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            VStack(alignment: .leading, spacing: 26) {
                Text(signedInAs == nil ? "Sign In to Encore" : "You're In")
                    .font(.system(size: titleSize, weight: .bold))
                if let signedInAs {
                    Label("Signed in as \(signedInAs)", systemImage: "checkmark.circle.fill")
                        .font(.system(size: bodySize, weight: .medium))
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        step(1, "Scan the code with your iPhone's camera.")
                        step(2, "Tap Open Encore, check the account, and tap Sign In TV.")
                        Text("Or in Encore on your iPhone, go to Settings › Encore Cloud › Sign In an Apple TV and enter:")
                            .font(.system(size: bodySize * 0.85))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let code { CodeDisplay(code: code.code) }
                    else if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    else { ProgressView() }
                    Button("Use Email and Password Instead", action: useEmail)
                        .pillButtonStyle(.secondary)
                }
            }
            .frame(maxWidth: textWidth, alignment: .leading)

            ZStack {
                RoundedRectangle(cornerRadius: qrSize * 0.08, style: .continuous).fill(Color.white)
                if let code, let image = Self.qr(app.cloud?.pairingPage(for: code.code)) {
                    Image(decorative: image, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .padding(qrSize * 0.07)
                } else {
                    ProgressView().tint(.black)
                }
            }
            .frame(width: qrSize, height: qrSize)
            .opacity(signedInAs == nil ? 1 : 0.25)
            .accessibilityLabel("QR code to sign in with your iPhone")
        }
        .padding(spacing)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await run() }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text("\(number)")
                .font(.system(size: bodySize * 0.8, weight: .bold))
                .frame(width: bodySize * 1.4, height: bodySize * 1.4)
                .liquidGlass(in: Circle())
            Text(text).font(.system(size: bodySize)).fixedSize(horizontal: false, vertical: true)
        }
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
                        withAnimation(Theme.Motion.content) { signedInAs = app.settings.accountEmail ?? app.household.name }
                        try? await Task.sleep(for: .seconds(1.5))
                        onSignedIn()
                        return
                    }
                }
            } catch is CancellationError {
                return
            } catch CloudClient.CloudError.expired {
                continue   // a fresh code
            } catch {
                self.error = "Couldn't reach Encore Cloud. Retrying…"
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    static func qr(_ url: URL?) -> CGImage? {
        guard let url else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 16, y: 16))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }

    #if os(tvOS)
    private let qrSize: CGFloat = 520
    private let titleSize: CGFloat = 64
    private let bodySize: CGFloat = 32
    private let textWidth: CGFloat = 900
    private let spacing: CGFloat = 100
    #else
    private let qrSize: CGFloat = 260
    private let titleSize: CGFloat = 30
    private let bodySize: CGFloat = 16
    private let textWidth: CGFloat = 420
    private let spacing: CGFloat = 40
    #endif
}
#endif
