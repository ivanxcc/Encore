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
    enum Kind { case primary, secondary }
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
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .foregroundStyle(foreground(active))
                .background(background(active), in: Capsule())
                .scaleEffect(configuration.isPressed ? 0.95 : (active ? scaleUp : 1))
                .shadow(color: .black.opacity(active ? 0.35 : 0), radius: 16, y: 8)
                .animation(Theme.Motion.focus, value: active)
                .animation(Theme.Motion.focus, value: configuration.isPressed)
                #if os(macOS)
                .onHover { hovering = $0 }
                #endif
        }

        private func foreground(_ active: Bool) -> Color {
            switch kind {
            case .primary: .black
            case .secondary: active ? .black : .white
            }
        }

        private func background(_ active: Bool) -> AnyShapeStyle {
            switch kind {
            case .primary: AnyShapeStyle(Color.white.opacity(active ? 1 : 0.92))
            case .secondary: active ? AnyShapeStyle(Color.white) : AnyShapeStyle(.ultraThinMaterial)
            }
        }

        #if os(tvOS)
        private let labelFont = Font.system(size: 28, weight: .semibold)
        private let horizontalPadding: CGFloat = 40
        private let verticalPadding: CGFloat = 18
        private let scaleUp: CGFloat = 1.08
        #else
        private let labelFont = Font.system(.headline)
        private let horizontalPadding: CGFloat = 22
        private let verticalPadding: CGFloat = 11
        private let scaleUp: CGFloat = 1.03
        #endif
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
