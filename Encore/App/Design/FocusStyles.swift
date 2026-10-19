import SwiftUI

/// How a card responds to the platform's pointer of attention:
///  - tvOS: the system `.card` style, i.e. the real Apple TV focus engine (lift, parallax tilt with the
///    remote's touch surface, specular highlight). Imitating it would only ever be worse.
///  - macOS: a gentle lift and shadow on hover, press-down on click.
///  - iOS/iPadOS: press-down on touch, plus the iPad pointer lift.
struct EncoreCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CardBody(configuration: configuration)
    }

    private struct CardBody: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .scaleEffect(scale)
                .shadow(color: .black.opacity(hovering ? 0.5 : 0), radius: hovering ? 18 : 0, y: hovering ? 10 : 0)
                .animation(reduceMotion ? nil : Theme.Motion.focus, value: hovering)
                .animation(reduceMotion ? nil : Theme.Motion.focus, value: configuration.isPressed)
                #if os(macOS)
                .onHover { hovering = $0 }
                #endif
        }

        private var scale: CGFloat {
            if configuration.isPressed { return 0.96 }
            return hovering ? 1.04 : 1
        }
    }
}

extension View {
    /// Apply the platform's card interaction to a Button.
    @ViewBuilder func cardButtonStyle() -> some View {
        #if os(tvOS)
        self.buttonStyle(.card)
        #elseif os(iOS)
        self.buttonStyle(EncoreCardStyle()).hoverEffect(.lift)
        #else
        self.buttonStyle(EncoreCardStyle())
        #endif
    }
}

/// The white capsule "Play" button and its translucent secondary siblings, as on Apple TV detail pages.
struct PillButtonStyle: ButtonStyle {
    /// `icon` is a translucent circle for a lone SF Symbol (+, checkmark, list), Apple TV style.
    /// `tab` is a season (or similar) picker: the chosen one reads as chosen without looking focused.
    enum Kind: Equatable { case primary, secondary, icon, tab(selected: Bool) }
    var kind: Kind = .primary

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, kind: kind)
    }

    private struct PillBody: View {
        let configuration: Configuration
        let kind: Kind
        @Environment(\.isFocused) private var focused
        @State private var hovering = false

        var body: some View {
            let active = focused || hovering
            configuration.label
                .font(labelFont)
                .lineLimit(1)
                .fixedSize()                       // a title never wraps into a two-line, oddly shaped pill
                .padding(.horizontal, kind == .icon ? 0 : horizontalPadding)
                .padding(.vertical, kind == .icon ? 0 : verticalPadding)
                .frame(width: kind == .icon ? iconDiameter : nil, height: kind == .icon ? iconDiameter : nil)
                .foregroundStyle(foreground(active))
                .modifier(PillBackground(kind: kind, active: active))
                .scaleEffect(configuration.isPressed ? 0.95 : (active ? scaleUp : 1))
                .shadow(color: .black.opacity(active ? 0.35 : 0), radius: 16, y: 8)
                .animation(Theme.Motion.focus, value: active)
                .animation(Theme.Motion.focus, value: configuration.isPressed)
                #if os(macOS)
                .onHover { hovering = $0 }
                #endif
        }

        private func foreground(_ active: Bool) -> Color {
            if active { return .black }
            switch kind {
            case .primary: return PillBackground.primaryIsSolid ? .black : .white
            case .secondary, .icon: return .white
            case let .tab(selected): return selected ? .white : .white.opacity(0.6)
            }
        }


        #if os(tvOS)
        private let labelFont = Font.system(size: 28, weight: .semibold)
        private let horizontalPadding: CGFloat = 40
        private let verticalPadding: CGFloat = 18
        private let scaleUp: CGFloat = 1.08
        private let iconDiameter: CGFloat = 66
        #else
        private let iconDiameter: CGFloat = 44
        private let labelFont = Font.system(.headline)
        private let horizontalPadding: CGFloat = 22
        private let verticalPadding: CGFloat = 11
        private let scaleUp: CGFloat = 1.03
        #endif
    }
}

/// Only the focused button is white, as on Apple TV, so it is always obvious where focus is. Unfocused,
/// every pill is Liquid Glass: the primary one a brighter glass, a selected tab a quiet glass, an
/// unselected tab just its label. Without focus (iPhone, iPad, Mac) the primary pill stays solid white.
private struct PillBackground: ViewModifier {
    let kind: PillButtonStyle.Kind
    let active: Bool

    #if os(tvOS)
    static let primaryIsSolid = false
    #else
    static let primaryIsSolid = true
    #endif

    func body(content: Content) -> some View {
        if active {
            content.background(Color.white, in: Capsule())
        } else {
            switch kind {
            case .primary:
                if Self.primaryIsSolid {
                    content.background(Color.white.opacity(0.92), in: Capsule())
                } else {
                    content.liquidGlass(in: Capsule(), tint: .white.opacity(0.28))
                }
            case .secondary, .icon:
                content.liquidGlass(in: Capsule())
            case let .tab(selected):
                if selected { content.liquidGlass(in: Capsule()) } else { content }
            }
        }
    }
}

extension View {
    /// The pill style needs the button's own focus on tvOS; `.plain` would draw the system highlight
    /// on top, so the platform focus effect is disabled and the style draws focus itself.
    @ViewBuilder func pillButtonStyle(_ kind: PillButtonStyle.Kind = .primary) -> some View {
        #if os(tvOS)
        self.buttonStyle(PillButtonStyle(kind: kind)).focusEffectDisabled()
        #else
        self.buttonStyle(PillButtonStyle(kind: kind))
        #endif
    }
}

extension View {
    /// Groups a row for the tvOS focus engine (and macOS keyboard focus); no-op on iOS, which has none.
    @ViewBuilder func tvFocusSection() -> some View {
        #if os(iOS)
        self
        #else
        self.focusSection()
        #endif
    }
}
