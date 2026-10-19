import SwiftUI
import EncoreKit

/// Review scores as compact badges, shown on the same line as the year and runtime, the way the Apple TV
/// app shows Rotten Tomatoes: an icon and the number, never a sentence in the synopsis.
struct RatingBadges: View {
    let ratings: [Rating]

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(ratings, id: \.source) { RatingBadge(rating: $0) }
        }
    }

    private var spacing: CGFloat {
        #if os(tvOS)
        return 22
        #else
        return 12
        #endif
    }
}

struct RatingBadge: View {
    let rating: Rating

    var body: some View {
        HStack(spacing: 6) {
            icon
            Text(rating.value)
                .font(Theme.Fonts.meta.monospacedDigit())
                .foregroundStyle(Theme.Colors.primary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder private var icon: some View {
        switch rating.source {
        case .rottenTomatoes:
            Image(rating.isFresh ? "rt-fresh" : "rt-rotten").resizable().frame(width: iconSize, height: iconSize)
        case .rottenTomatoesAudience:
            Image("rt-audience").resizable().frame(width: iconSize, height: iconSize)
        case .imdb:
            Text("IMDb")
                .font(.system(size: iconSize * 0.58, weight: .black))
                .foregroundStyle(.black)
                .padding(.horizontal, iconSize * 0.18)
                .frame(height: iconSize * 0.95)
                .background(Color(red: 0.96, green: 0.77, blue: 0.09), in: RoundedRectangle(cornerRadius: iconSize * 0.16))
        case .metacritic:
            Text("M")
                .font(.system(size: iconSize * 0.6, weight: .black))
                .foregroundStyle(.white)
                .frame(width: iconSize, height: iconSize)
                .background(metacriticColor, in: RoundedRectangle(cornerRadius: iconSize * 0.18))
        case .letterboxd:
            HStack(spacing: -iconSize * 0.12) {
                Circle().fill(Color(red: 1, green: 0.5, blue: 0))
                Circle().fill(Color(red: 0, green: 0.88, blue: 0.33))
                Circle().fill(Color(red: 0.25, green: 0.74, blue: 0.96))
            }
            .frame(width: iconSize * 1.4, height: iconSize * 0.55)
        case .tmdb:
            Text("TMDB")
                .font(.system(size: iconSize * 0.5, weight: .heavy))
                .foregroundStyle(Color(red: 0.0, green: 0.82, blue: 0.69))
        }
    }

    private var metacriticColor: Color {
        rating.score >= 61 ? Color(red: 0.4, green: 0.8, blue: 0.2)
            : rating.score >= 40 ? Color(red: 1, green: 0.8, blue: 0.2) : Color(red: 1, green: 0, blue: 0)
    }

    private var iconSize: CGFloat {
        #if os(tvOS)
        return 30
        #else
        return 17
        #endif
    }

    private var accessibilityText: String {
        switch rating.source {
        case .rottenTomatoes: "Rotten Tomatoes \(rating.value)"
        case .rottenTomatoesAudience: "Audience score \(rating.value)"
        case .imdb: "IMDb \(rating.value)"
        case .metacritic: "Metacritic \(rating.value)"
        case .letterboxd: "Letterboxd \(rating.value)"
        case .tmdb: "TMDB \(rating.value)"
        }
    }
}

/// "2024 · 2h 14m · Drama" followed by the rating badges, on one line that wraps gracefully.
struct MetaInfoLine: View {
    let parts: [String?]
    let ratings: [Rating]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { MetaLine(parts: parts); RatingBadges(ratings: ratings) }
            VStack(alignment: .leading, spacing: 8) { MetaLine(parts: parts); RatingBadges(ratings: ratings) }
        }
    }
}

/// The iPhone form of `MetaInfoLine`: centered, with the badges on a line of their own when the
/// details are long, as the Apple TV app sets it under a centered logo.
struct CenteredInfoLine: View {
    let parts: [String?]
    let ratings: [Rating]

    var body: some View {
        let text = parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Text(text).lineLimit(1)
                RatingBadges(ratings: ratings)
            }
            VStack(spacing: 8) {
                Text(text).multilineTextAlignment(.center).lineLimit(2)
                RatingBadges(ratings: ratings)
            }
        }
        .font(Theme.Fonts.meta)
        .foregroundStyle(Theme.Colors.secondary)
        .frame(maxWidth: .infinity)
    }
}
