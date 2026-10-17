import SwiftUI
import MarqueeKit

/// "Who's watching?", with the household shown above so it is always clear whose accounts these are.
struct ProfilePickerView: View {
    @EnvironmentObject private var app: AppModel
    @State private var pinTarget: Profile?
    @State private var showHouseholds = false

    var body: some View {
        VStack(spacing: 44) {
            Spacer()
            Button { showHouseholds = true } label: {
                Label(app.household.name, systemImage: app.household.symbol)
            }
            .pillButtonStyle(.secondary)

            Text("Who's watching?")
                .font(Theme.Fonts.heroTitle)
                .foregroundStyle(Theme.Colors.primary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Metrics.itemSpacing * 1.5) {
                    ForEach(app.profiles) { profile in
                        ProfileAvatarButton(profile: profile) {
                            if profile.hasPin { pinTarget = profile } else { app.activeProfile = profile }
                        }
                    }
                }
                .padding(40)
                .frame(maxWidth: .infinity)
            }
            .scrollClipDisabled()
            .focusSection()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $pinTarget) { profile in
            PinEntryView(profile: profile) { app.activeProfile = profile }
        }
        .sheet(isPresented: $showHouseholds) {
            NavigationStack { HouseholdsView() }
        }
    }
}

struct ProfileAvatar: View {
    let profile: Profile
    var size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Theme.Colors.avatarColors[profile.colorIndex % Theme.Colors.avatarColors.count].gradient)
            if profile.avatar.unicodeScalars.first?.properties.isEmojiPresentation == true {
                Text(profile.avatar).font(.system(size: size * 0.5))
            } else {
                Image(systemName: profile.avatar)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }
}

private struct ProfileAvatarButton: View {
    let profile: Profile
    let action: () -> Void

    #if os(tvOS)
    private let size: CGFloat = 220
    #else
    private let size: CGFloat = 120
    #endif

    var body: some View {
        VStack(spacing: 16) {
            Button(action: action) {
                ProfileAvatar(profile: profile, size: size)
                    .overlay(alignment: .bottomTrailing) {
                        if profile.hasPin {
                            Image(systemName: "lock.fill")
                                .font(.system(size: size * 0.12, weight: .bold))
                                .padding(size * 0.06)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                    }
                    .clipShape(Circle())
            }
            .cardButtonStyle()
            .clipShape(Circle())
            Text(profile.name)
                .font(Theme.Fonts.cardTitle)
                .foregroundStyle(Theme.Colors.secondary)
        }
    }
}

/// A 4-digit PIN pad that works with a remote, a keyboard, and touch.
struct PinEntryView: View {
    let profile: Profile
    let onUnlock: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var digits = ""
    @State private var wrong = false

    var body: some View {
        VStack(spacing: 30) {
            ProfileAvatar(profile: profile, size: 90)
            Text("Enter PIN for \(profile.name)").font(Theme.Fonts.shelfTitle)
            HStack(spacing: 18) {
                ForEach(0..<4, id: \.self) { index in
                    Circle()
                        .fill(index < digits.count ? Color.white : Color.white.opacity(0.2))
                        .frame(width: 18, height: 18)
                }
            }
            .modifier(Shake(trigger: wrong ? 1 : 0))
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(90), spacing: 18), count: 3), spacing: 18) {
                ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "⌫"], id: \.self) { key in
                    if key.isEmpty {
                        Color.clear.frame(height: 70)
                    } else {
                        Button(key) { press(key) }
                            .font(.title2.weight(.medium))
                            .frame(width: 90, height: 70)
                            .pillButtonStyle(.secondary)
                    }
                }
            }
            Button("Cancel") { dismiss() }
        }
        .padding(40)
        .marqueeCanvas()
    }

    private func press(_ key: String) {
        wrong = false
        if key == "⌫" { if !digits.isEmpty { digits.removeLast() }; return }
        guard digits.count < 4 else { return }
        digits += key
        guard digits.count == 4 else { return }
        if profile.pinMatches(digits) {
            dismiss()
            onUnlock()
        } else {
            withAnimation(.default) { wrong = true }
            digits = ""
        }
    }
}

private struct Shake: GeometryEffect {
    var trigger: CGFloat
    var animatableData: CGFloat {
        get { trigger }
        set { trigger = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 10 * sin(trigger * .pi * 6), y: 0))
    }
}
