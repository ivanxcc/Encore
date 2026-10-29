#if !os(tvOS)
import SwiftUI
import EncoreKit

/// Downloads: what's saved on this device for watching offline, how much space each title takes, and
/// how much Encore uses next to what's free. Shows are grouped, with their episodes one tap away.
struct DownloadsView: View {
    @ObservedObject private var downloads = DownloadManager.shared
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var playback: PlaybackCenter
    @State private var confirmDeleteAll = false

    var body: some View {
        List {
            Section {
                StorageSummary()
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            }
            if downloads.records.isEmpty {
                ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle",
                                       description: Text("Download movies and episodes from their pages to watch without an internet connection."))
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(groups) { group in
                        if group.meta.type == "series" || group.records.contains(where: { $0.video != nil }) {
                            NavigationLink {
                                ShowDownloadsView(metaID: group.meta.id).pushedPage()
                            } label: {
                                DownloadTitleRow(meta: group.meta, records: group.records)
                            }
                        } else if let record = group.records.first {
                            DownloadRow(record: record)
                        }
                    }
                    .onDelete { offsets in
                        for offset in offsets { for record in groups[offset].records { downloads.remove(record.id) } }
                    }
                }
                Section {
                    Button("Delete All Downloads", role: .destructive) { confirmDeleteAll = true }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .pageTitle("Downloads")
        .confirmationDialog("Delete all downloads?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete All Downloads", role: .destructive) { downloads.removeAll() }
        } message: {
            Text("This frees \(Self.size(downloads.totalBytes)). You can download them again later.")
        }
    }

    struct TitleGroup: Identifiable {
        let meta: MetaPreview
        let records: [DownloadRecord]
        var id: String { meta.id }
    }

    /// Downloads grouped by title, most recently added first.
    private var groups: [TitleGroup] {
        Dictionary(grouping: downloads.records, by: \.meta.id).values
            .map { records in
                TitleGroup(meta: records[0].meta,
                      records: records.sorted { ($0.video?.season ?? 0, $0.video?.episode ?? 0) < ($1.video?.season ?? 0, $1.video?.episode ?? 0) })
            }
            .sorted { ($0.records.map(\.addedAt).max() ?? .distantPast) > ($1.records.map(\.addedAt).max() ?? .distantPast) }
    }

    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

/// A show's downloaded episodes.
private struct ShowDownloadsView: View {
    let metaID: String
    @ObservedObject private var downloads = DownloadManager.shared

    var body: some View {
        let records = downloads.records.filter { $0.meta.id == metaID }
            .sorted { ($0.video?.season ?? 0, $0.video?.episode ?? 0) < ($1.video?.season ?? 0, $1.video?.episode ?? 0) }
        List {
            ForEach(records) { DownloadRow(record: $0) }
                .onDelete { offsets in for offset in offsets { downloads.remove(records[offset].id) } }
        }
        .scrollContentBackground(.hidden)
        .pageTitle(records.first?.meta.name ?? "Downloads")
    }
}

/// How much Encore's downloads take, next to everything else on the device and what's free.
private struct StorageSummary: View {
    @ObservedObject private var downloads = DownloadManager.shared

    var body: some View {
        let total = max(1, downloads.totalCapacity)
        let encore = downloads.totalBytes
        let free = downloads.freeBytes
        let other = max(0, total - free - encore)
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    Capsule().fill(Color.accentColor)
                        .frame(width: max(encore > 0 ? 4 : 0, proxy.size.width * CGFloat(encore) / CGFloat(total)))
                    Capsule().fill(Color.white.opacity(0.35))
                        .frame(width: proxy.size.width * CGFloat(other) / CGFloat(total))
                    Capsule().fill(Color.white.opacity(0.12))
                }
            }
            .frame(height: 8)
            HStack(spacing: 14) {
                legend(Color.accentColor, "Encore", encore)
                legend(Color.white.opacity(0.35), "Other", other)
                Spacer()
                Text("\(DownloadsView.size(free)) free").foregroundStyle(.secondary)
            }
            .font(.footnote)
        }
        .padding(.horizontal, 4)
    }

    private func legend(_ color: Color, _ label: String, _ bytes: Int64) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(label) \(DownloadsView.size(bytes))")
        }
    }
}

/// A show in the list: its poster, name, and how many episodes and how much space.
private struct DownloadTitleRow: View {
    let meta: MetaPreview
    let records: [DownloadRecord]
    @ObservedObject private var downloads = DownloadManager.shared

    var body: some View {
        HStack(spacing: 14) {
            Poster(meta: meta)
            VStack(alignment: .leading, spacing: 4) {
                Text(meta.name).font(.headline)
                let bytes = records.reduce(0) { $0 + downloads.bytes($1) }
                Text("\(records.count) episode\(records.count == 1 ? "" : "s") · \(DownloadsView.size(bytes))")
                    .font(.subheadline).foregroundStyle(.secondary)
                if records.contains(where: { $0.state == .downloading }) {
                    Text("Downloading…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// One film or episode: what it is, its quality and size (or progress), and what can be done with it.
struct DownloadRow: View {
    let record: DownloadRecord
    @ObservedObject private var downloads = DownloadManager.shared
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var playback: PlaybackCenter

    var body: some View {
        HStack(spacing: 14) {
            if record.video == nil { Poster(meta: record.meta) }
            VStack(alignment: .leading, spacing: 5) {
                Text(record.video == nil ? record.meta.name : record.displayTitle)
                    .font(.headline).lineLimit(2)
                status
            }
            Spacer(minLength: 8)
            action
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { if record.state == .finished { playback.playDownload(record, app: app) } }
        .contextMenu {
            if record.state == .finished {
                Button("Play", systemImage: "play.fill") { playback.playDownload(record, app: app) }
            }
            Button("Delete Download", systemImage: "trash", role: .destructive) { downloads.remove(record.id) }
        }
    }

    @ViewBuilder private var status: some View {
        let quality = [record.resolution, record.quality.label].compactMap { $0 }.joined(separator: " · ")
        switch record.state {
        case .finished:
            Text("\(quality) · \(DownloadsView.size(downloads.bytes(record)))")
                .font(.subheadline).foregroundStyle(.secondary)
        case .downloading, .queued:
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: record.progress).tint(.white)
                Text(progressText).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        case .paused:
            Text("Paused · \(progressText)").font(.caption).foregroundStyle(.secondary)
        case .failed:
            Text(record.error ?? "Download failed.").font(.caption).foregroundStyle(.orange).lineLimit(2)
        }
    }

    private var progressText: String {
        let received = DownloadsView.size(record.receivedBytes)
        guard let expected = record.expectedBytes, expected > 0 else { return received }
        return "\(received) of \(DownloadsView.size(expected))"
    }

    @ViewBuilder private var action: some View {
        switch record.state {
        case .finished:
            Button { playback.playDownload(record, app: app) } label: {
                Image(systemName: "play.circle.fill").font(.title)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play")
        case .downloading, .queued:
            Button { downloads.pause(record.id) } label: {
                ProgressRing(progress: record.progress, symbol: "pause.fill").frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Pause Download")
        case .paused:
            Button { downloads.resume(record.id) } label: {
                Image(systemName: "arrow.down.circle").font(.title)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Resume Download")
        case .failed:
            Button { Task { try? await downloads.retry(record.id, app: app) } } label: {
                Image(systemName: "arrow.clockwise.circle").font(.title)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retry Download")
        }
    }
}

private struct Poster: View {
    let meta: MetaPreview

    var body: some View {
        Artwork(url: meta.posterURL, maxPixel: 200)
            .frame(width: 54, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// A circle that fills with progress around a small symbol.
struct ProgressRing: View {
    let progress: Double
    var symbol: String = "stop.fill"

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.25), lineWidth: 2.5)
            Circle().trim(from: 0, to: max(0.02, progress))
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.4), value: progress)
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
        }
    }
}

/// The download button on a title page (and its episode menu's counterpart): download, see progress,
/// pause, cancel, play the download, or delete it.
struct DownloadButton: View {
    let meta: MetaPreview
    let video: Video?
    let runtime: TimeInterval?
    @ObservedObject private var downloads = DownloadManager.shared
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var playback: PlaybackCenter
    @State private var starting = false
    @State private var error: String?

    var body: some View {
        let record = downloads.record(video?.id ?? meta.id)
        Group {
            if let record {
                Menu {
                    switch record.state {
                    case .finished:
                        Button("Play Download", systemImage: "play.fill") { playback.playDownload(record, app: app) }
                    case .downloading, .queued:
                        Button("Pause Download", systemImage: "pause.fill") { downloads.pause(record.id) }
                    case .paused:
                        Button("Resume Download", systemImage: "arrow.down") { downloads.resume(record.id) }
                    case .failed:
                        Button("Try Again", systemImage: "arrow.clockwise") { Task { await retry(record) } }
                    }
                    Button(record.state == .finished ? "Delete Download" : "Cancel Download",
                           systemImage: "trash", role: .destructive) { downloads.remove(record.id) }
                } label: {
                    label(for: record)
                }
                .menuStyle(.button)
            } else {
                Button { Task { await start() } } label: {
                    if starting { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.down.to.line") }
                }
                .disabled(starting)
            }
        }
        .pillButtonStyle(.icon)
        .accessibilityLabel(accessibility(record))
        .alert("Couldn't Download", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    @ViewBuilder private func label(for record: DownloadRecord) -> some View {
        switch record.state {
        case .finished: Image(systemName: "checkmark.circle")
        case .downloading, .queued: ProgressRing(progress: record.progress).frame(width: 22, height: 22)
        case .paused: Image(systemName: "pause.circle")
        case .failed: Image(systemName: "exclamationmark.circle")
        }
    }

    private func accessibility(_ record: DownloadRecord?) -> String {
        switch record?.state {
        case nil: "Download"
        case .finished: "Downloaded"
        case .downloading, .queued: "Downloading"
        case .paused: "Download Paused"
        case .failed: "Download Failed"
        }
    }

    private func start() async {
        starting = true
        defer { starting = false }
        do {
            try await downloads.download(meta: meta, video: video, runtime: runtime, app: app)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func retry(_ record: DownloadRecord) async {
        do { try await downloads.retry(record.id, app: app) } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// Settings › Downloads: the quality and, on iPhone and iPad, whether cellular may be used.
struct DownloadSettingsSection: View {
    @AppStorage(DownloadManager.qualityKey) private var quality = DownloadQuality.standard.rawValue
    #if os(iOS)
    @AppStorage(DownloadManager.cellularKey) private var overCellular = false
    #endif
    @ObservedObject private var downloads = DownloadManager.shared

    var body: some View {
        Section {
            Picker("Download Quality", selection: $quality) {
                ForEach(DownloadQuality.allCases) { option in
                    VStack(alignment: .leading) {
                        Text(option.label)
                        Text(option.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(option.rawValue)
                }
            }
            #if os(iOS)
            Toggle("Download Over Cellular", isOn: $overCellular)
            #endif
            LabeledContent("Downloads Use", value: DownloadsView.size(downloads.totalBytes))
        } header: {
            Text("Downloads")
        } footer: {
            Text("Encore picks a release that fits the quality you choose: Standard is about 1 GB an hour of video, Higher about 2.5 GB. New downloads use the new setting.")
        }
    }
}
#endif
