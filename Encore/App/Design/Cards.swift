import SwiftUI
import EncoreKit

/// Poster card (2:3) with the title underneath, as on Apple TV shelves.
struct PosterCard: View {
    let meta: MetaPreview
    var width: CGFloat = Theme.Metrics.posterWidth
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: action) {
                Artwork(url: meta.poster, maxPixel: Int(width * 3))
                    .frame(width: width, height: width / Theme.Metrics.posterAspect)
                    .overlay {
                        if meta.poster == nil { TitlePlaceholder(title: meta.name) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous))
            }
            .cardButtonStyle()
            .accessibilityLabel(meta.name)
            Text(meta.name)
                .font(Theme.Fonts.cardTitle)
                .foregroundStyle(Theme.Colors.secondary)
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
        }
    }
}

/// Landscape card (16:9) with an optional progress bar: Continue Watching and episodes.
struct LandscapeCard: View {
    let image: URL?
    let title: String
    var subtitle: String? = nil
    var progress: Double? = nil
    var width: CGFloat = Theme.Metrics.landscapeWidth
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: action) {
                Artwork(url: image, maxPixel: Int(width * 2.5))
                    .frame(width: width, height: width / Theme.Metrics.landscapeAspect)
                    .overlay {
                        if image == nil { TitlePlaceholder(title: title) }
                    }
                    .overlay(alignment: .bottom) {
                        if let progress, progress > 0 {
                            ProgressBar(value: progress)
                                .padding(.horizontal, 14)
                                .padding(.bottom, 12)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous))
            }
            .cardButtonStyle()
            .accessibilityLabel(title)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Fonts.cardTitle)
                    .foregroundStyle(Theme.Colors.primary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Fonts.cardSubtitle)
                        .foregroundStyle(Theme.Colors.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: width, alignment: .leading)
        }
    }
}

struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { proxy in
            Capsule().fill(Theme.Colors.progressTrack)
                .overlay(alignment: .leading) {
                    Capsule().fill(Color.white).frame(width: proxy.size.width * min(1, max(0, value)))
                }
        }
        .frame(height: 5)
        .shadow(color: .black.opacity(0.4), radius: 4)
    }
}

/// When an add-on has no artwork, the title set in type is calmer than a broken-image glyph.
struct TitlePlaceholder: View {
    let title: String

    var body: some View {
        Text(title)
            .font(Theme.Fonts.cardTitle)
            .multilineTextAlignment(.center)
            .foregroundStyle(Theme.Colors.secondary)
            .padding()
    }
}

/// A titled horizontal shelf. Rows scroll with view-aligned snapping so the leading card always lands on
/// the content edge, and are focus sections on tvOS so up/down moves between rows predictably.
struct Shelf<Item: Identifiable, Card: View>: View {
    let title: String
    let items: [Item]
    @ViewBuilder let card: (Item) -> Card

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(Theme.Fonts.shelfTitle)
                .foregroundStyle(Theme.Colors.primary)
                .padding(.horizontal, Theme.Metrics.edge)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.Metrics.itemSpacing) {
                    ForEach(items) { card($0) }
                }
                .scrollTargetLayout()
                .padding(.horizontal, Theme.Metrics.edge)
                #if os(tvOS)
                .padding(.vertical, 30)   // room for the focus lift so it is never clipped
                #else
                .padding(.vertical, 6)
                #endif
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollClipDisabled()
            .tvFocusSection()
        }
    }
}

/// Shelf placeholder while a catalog loads: same geometry, so nothing jumps when content arrives.
struct ShelfPlaceholder: View {
    let title: String
    var landscape = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(Theme.Fonts.shelfTitle)
                .foregroundStyle(Theme.Colors.tertiary)
                .padding(.horizontal, Theme.Metrics.edge)
            HStack(spacing: Theme.Metrics.itemSpacing) {
                ForEach(0..<8, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous)
                        .fill(Theme.Colors.placeholder)
                        .frame(width: landscape ? Theme.Metrics.landscapeWidth : Theme.Metrics.posterWidth,
                               height: landscape ? Theme.Metrics.landscapeWidth / Theme.Metrics.landscapeAspect
                                                 : Theme.Metrics.posterWidth / Theme.Metrics.posterAspect)
                }
            }
            .padding(.horizontal, Theme.Metrics.edge)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
        .redacted(reason: .placeholder)
    }
}
