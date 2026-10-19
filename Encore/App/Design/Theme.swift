import SwiftUI

/// The visual language, modeled on the Apple TV app: true-black canvas, full-bleed artwork, white type
/// in SF Pro, generous spacing, and content that moves (never chrome). One set of tokens with
/// per-platform metrics, so the same component reads right at ten feet, at arm's length, and on a desk.
enum Theme {
    enum Metrics {
        #if os(tvOS)
        static let edge: CGFloat = 80
        static let shelfSpacing: CGFloat = 48
        static let itemSpacing: CGFloat = 40
        static let posterWidth: CGFloat = 230
        static let landscapeWidth: CGFloat = 410
        static let heroHeightRatio: CGFloat = 0.88
        static let cornerRadius: CGFloat = 12
        #elseif os(macOS)
        static let edge: CGFloat = 40
        static let shelfSpacing: CGFloat = 34
        static let itemSpacing: CGFloat = 20
        static let posterWidth: CGFloat = 170
        static let landscapeWidth: CGFloat = 300
        static let heroHeightRatio: CGFloat = 0.62
        static let cornerRadius: CGFloat = 10
        #else
        static let edge: CGFloat = 20
        static let shelfSpacing: CGFloat = 28
        static let itemSpacing: CGFloat = 12
        static let posterWidth: CGFloat = 128
        static let landscapeWidth: CGFloat = 264
        static let heroHeightRatio: CGFloat = 0.62
        static let cornerRadius: CGFloat = 10
        #endif

        static let posterAspect: CGFloat = 2.0 / 3.0
        static let landscapeAspect: CGFloat = 16.0 / 9.0
    }

    enum Colors {
        static let canvas = Color.black
        static let primary = Color.white
        static let secondary = Color.white.opacity(0.62)
        static let tertiary = Color.white.opacity(0.4)
        static let placeholder = Color.white.opacity(0.08)
        static let progressTrack = Color.white.opacity(0.28)
        static let avatarColors: [Color] = [
            Color(red: 0.22, green: 0.48, blue: 0.98), Color(red: 0.95, green: 0.36, blue: 0.36),
            Color(red: 0.98, green: 0.69, blue: 0.20), Color(red: 0.30, green: 0.78, blue: 0.47),
            Color(red: 0.64, green: 0.40, blue: 0.95), Color(red: 0.98, green: 0.45, blue: 0.70),
        ]
    }

    enum Motion {
        /// The focus/hover lift: quick to respond, settles without bounce, like tvOS focus.
        static let focus = Animation.spring(response: 0.3, dampingFraction: 0.82)
        static let content = Animation.smooth(duration: 0.35)
        static let hero = Animation.easeInOut(duration: 0.8)
    }

    enum Fonts {
        #if os(tvOS)
        static let heroTitle = Font.system(size: 72, weight: .bold)
        static let shelfTitle = Font.system(size: 34, weight: .semibold)
        static let cardTitle = Font.system(size: 24, weight: .medium)
        static let cardSubtitle = Font.system(size: 20, weight: .regular)
        static let body = Font.system(size: 28)
        static let meta = Font.system(size: 24, weight: .medium)
        #elseif os(macOS)
        static let heroTitle = Font.system(size: 46, weight: .bold)
        static let shelfTitle = Font.system(size: 20, weight: .semibold)
        static let cardTitle = Font.system(size: 13, weight: .medium)
        static let cardSubtitle = Font.system(size: 12)
        static let body = Font.system(size: 14)
        static let meta = Font.system(size: 13, weight: .medium)
        #else
        static let heroTitle = Font.system(size: 34, weight: .bold)
        static let shelfTitle = Font.system(.title3, weight: .semibold)
        static let cardTitle = Font.system(.subheadline, weight: .medium)
        static let cardSubtitle = Font.footnote
        static let body = Font.body
        static let meta = Font.system(.footnote, weight: .medium)
        #endif
    }
}

extension View {
    /// Black canvas, dark appearance, white tint: the base of every screen.
    func encoreCanvas() -> some View {
        self
            .background(Theme.Colors.canvas.ignoresSafeArea())
            .preferredColorScheme(.dark)
            .tint(.white)
    }

    /// Bottom scrim that keeps white text legible on any artwork.
    func bottomScrim(_ strength: Double = 0.85) -> some View {
        overlay(alignment: .bottom) {
            LinearGradient(stops: [.init(color: .clear, location: 0),
                                   .init(color: .black.opacity(strength * 0.6), location: 0.55),
                                   .init(color: .black.opacity(strength), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        }
    }
}
