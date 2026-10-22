import SwiftUI
import EncoreKit

/// "Who's watching?", with the household shown above so it is always clear whose accounts these are.
struct ProfilePickerView: View {
    @EnvironmentObject private var app: AppModel
    @State private var pinTarget: Profile?
    @State private var showHouseholds = false
    @State private var rowWidth: CGFloat = 0

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
                // At least as wide as the screen, so a few profiles sit centered (a scroll view's content
                // otherwise hugs the leading edge); more than fit still scroll.
                .frame(minWidth: rowWidth)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
            .scrollClipDisabled()
            .tvFocusSection()
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

/// A profile in "Who's watching?". The one under the pointer (Mac) or the remote's focus (Apple TV)
/// grows a little and gets a white ring, and its name brightens, so it's plain which one a click picks.
private struct ProfileAvatarButton: View {
    let profile: Profile
    let action: () -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool

    #if os(tvOS)
    private let size: CGFloat = 220
    private let ring: CGFloat = 7
    #else
    private let size: CGFloat = 120
    private let ring: CGFloat = 4
    #endif

    private var highlighted: Bool { hovering || focused }

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
                    .overlay {
                        Circle()
                            .strokeBorder(.white, lineWidth: ring)
                            .padding(-ring * 1.6)
                            .opacity(highlighted ? 1 : 0)
                    }
                    .scaleEffect(highlighted ? 1.1 : 1)
                    .shadow(color: .black.opacity(highlighted ? 0.55 : 0), radius: size * 0.12, y: size * 0.06)
                    .contentShape(Circle())
            }
            .buttonStyle(AvatarPressStyle())
            .focused($focused)
            .onHover { hovering = $0 }
            Text(profile.name)
                .font(Theme.Fonts.cardTitle.weight(highlighted ? .semibold : .regular))
                .foregroundStyle(highlighted ? Theme.Colors.primary : Theme.Colors.secondary)
                .offset(y: highlighted ? size * 0.06 : 0)
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: highlighted)
    }
}

/// Presses in slightly; the hover and focus highlight are drawn by the avatar itself.
private struct AvatarPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
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
        .encoreCanvas()
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
