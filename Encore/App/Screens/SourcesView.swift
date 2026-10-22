import SwiftUI
import EncoreKit

/// Every available source, best first, like Apple TV's "How to Watch". Picking one plays exactly that
/// source (never silently swapped for another).
struct SourcesView: View {
    let meta: MetaPreview
    let video: Video?
    /// What a pick does. Defaults to closing this sheet and playing the pick.
    var onPick: ((RankedStream) -> Void)? = nil
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var playback: PlaybackCenter
    @Environment(\.dismiss) private var dismiss
    @State private var streams: [RankedStream]?

    var body: some View {
        NavigationStack {
            Group {
                if let streams, streams.isEmpty {
                    ContentUnavailableView("No Sources",
                                           systemImage: "play.slash",
                                           description: Text(emptyHint))
                } else if let streams {
                    List(streams) { ranked in
                        Button {
                            if let onPick {
                                onPick(ranked)
                            } else {
                                dismiss()
                                playback.play(meta: meta, video: video, app: app, explicit: ranked, afterDismissal: true)
                            }
                        } label: {
                            SourceRow(ranked: ranked)
                        }
                    }
                } else {
                    ProgressView("Finding sources…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(video?.episodeLabel.map { "\(meta.name) · \($0)" } ?? meta.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .task {
            let id = video?.id ?? meta.id
            streams = await app.session.rankedStreams(type: meta.type, id: id, limits: NetworkMonitor.shared.limits) { partial in
                await MainActor.run { if !partial.isEmpty { streams = partial } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 620, minHeight: 520)
        #endif
    }

    private var emptyHint: String {
        app.settings.addons.contains { $0.manifest.resources.contains { $0.name == "stream" } }
            ? "Your add-ons didn't return anything playable for this title."
            : "Install a streaming add-on in Settings to see sources here."
    }
}

private struct SourceRow: View {
    let ranked: RankedStream

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let label = ranked.traits.resolution.label { Badge(text: label, strong: true) }
                if ranked.traits.isDolbyVision { Badge(text: "Dolby Vision") }
                else if ranked.traits.isHDR { Badge(text: "HDR") }
                if ranked.traits.isRemux { Badge(text: "REMUX") }
                if let audio = ranked.traits.audioLabel { Badge(text: audio) }
                if ranked.traits.isCached { Badge(text: "Instant") }
                if ranked.stream.url == nil { Badge(text: "Torrent") }
                Spacer()
                Text(ranked.addon.manifest.name).font(Theme.Fonts.cardSubtitle).foregroundStyle(Theme.Colors.tertiary)
            }
            Text(detailLine)
                .font(Theme.Fonts.cardSubtitle)
                .foregroundStyle(Theme.Colors.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 6)
    }

    private var detailLine: String {
        var parts: [String] = []
        if let size = ranked.traits.sizeBytes {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if let codec = ranked.traits.codec { parts.append(codec) }
        if let seeders = ranked.traits.seeders { parts.append("\(seeders) seeders") }
        let name = ranked.stream.behaviorHints?.filename
            ?? ranked.stream.details.split(separator: "\n").first.map(String.init) ?? ""
        if !name.isEmpty { parts.append(name) }
        return parts.joined(separator: "  ·  ")
    }
}

struct Badge: View {
    let text: String
    var strong = false

    var body: some View {
        Text(text)
            .font(Theme.Fonts.cardSubtitle.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(strong ? Color.black : Color.white)
            .background(strong ? Color.white : Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
    }
}
