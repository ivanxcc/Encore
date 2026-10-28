#if os(iOS)
import SwiftUI
import MediaPlayer
import AVFoundation

/// iPhone and iPad playback: brightness on the left edge and volume on the right, as thin sliders. Volume is the system volume (the same as the side buttons).
struct SideSliders: View {
    /// Called while a slider is being used, so the player keeps its controls on screen.
    let onInteract: () -> Void
    @State private var brightness = Double(UIScreen.main.brightness)
    @StateObject private var volume = SystemVolume()

    var body: some View {
        HStack {
            VerticalSlider(value: $brightness, systemImage: brightnessSymbol, label: "Brightness", onInteract: onInteract)
                .onChange(of: brightness) { _, value in UIScreen.main.brightness = CGFloat(value) }
            Spacer()
            VerticalSlider(value: Binding(get: { volume.level }, set: { volume.set($0) }),
                           systemImage: volumeSymbol, label: "Volume", onInteract: onInteract)
        }
        .padding(.horizontal, 30)
        .background(SystemVolume.Host(volume: volume).frame(width: 1, height: 1).opacity(0.01))
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.brightnessDidChangeNotification)) { _ in
            brightness = Double(UIScreen.main.brightness)
        }
    }

    private var brightnessSymbol: String { brightness < 0.33 ? "sun.min.fill" : "sun.max.fill" }

    private var volumeSymbol: String {
        switch volume.level {
        case ..<0.01: "speaker.slash.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }
}

/// A slim rounded bar that fills white from the bottom over a grey track, its icon above it, as in
/// Netflix's player. The touch area is much wider than the bar, so it's easy to grab; drag anywhere on it
/// to change the level.
private struct VerticalSlider: View {
    @Binding var value: Double
    let systemImage: String
    let label: String
    let onInteract: () -> Void
    @State private var dragging = false
    @State private var startValue: Double?

    private let height: CGFloat = 150
    private var barWidth: CGFloat { dragging ? 8 : 6 }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 3)
                .frame(width: 28, height: 22)
                .contentTransition(.symbolEffect(.replace))
            ZStack(alignment: .bottom) {
                Capsule().fill(Color(white: 0.35))
                    .frame(width: barWidth, height: height)
                Rectangle().fill(.white)
                    .frame(width: barWidth, height: height * value)
            }
            .clipShape(Capsule())
            .frame(width: 44, height: height)
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: dragging)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { drag in
                let start = startValue ?? value
                if startValue == nil { startValue = start; dragging = true }
                // Relative, like the system's: drag up from wherever the level is.
                value = min(1, max(0, start - Double(drag.translation.height / height)))
                onInteract()
            }
            .onEnded { _ in
                startValue = nil
                dragging = false
            })
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(1, value + 0.1)
            case .decrement: value = max(0, value - 0.1)
            @unknown default: break
            }
        }
    }
}

/// The system volume: read from the audio session, set through a hidden system volume view (the only
/// way an app may change it), so the system doesn't show its own volume overlay over the video.
@MainActor
final class SystemVolume: ObservableObject {
    @Published private(set) var level = Double(AVAudioSession.sharedInstance().outputVolume)
    fileprivate weak var slider: UISlider?
    private var observation: NSKeyValueObservation?

    init() {
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume) { [weak self] session, _ in
            let value = Double(session.outputVolume)
            Task { @MainActor in self?.level = value }
        }
    }

    func set(_ value: Double) {
        level = value
        slider?.value = Float(value)
        slider?.sendActions(for: .valueChanged)
    }

    struct Host: UIViewRepresentable {
        let volume: SystemVolume

        func makeUIView(context: Context) -> MPVolumeView {
            let view = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 1, height: 1))
            view.showsVolumeSlider = true
            volume.slider = view.subviews.compactMap { $0 as? UISlider }.first
            return view
        }

        func updateUIView(_ view: MPVolumeView, context: Context) {
            if volume.slider == nil { volume.slider = view.subviews.compactMap { $0 as? UISlider }.first }
        }
    }
}
#endif
