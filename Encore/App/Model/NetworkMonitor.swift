import Foundation
import Network
import EncoreKit

/// Whether this device is on a costly connection (cellular, or a phone's personal hotspot), and the
/// source limits that apply there. iPhone and iPad only; Apple TV and Mac are never limited.
final class NetworkMonitor: @unchecked Sendable {
    static let shared = NetworkMonitor()

    /// Settings › Playback › "Quality on Cellular": the highest resolution chosen automatically on
    /// cellular, or 0 to treat cellular like Wi-Fi. 1080p by default.
    static let cellularQualityKey = "cellularMaxResolution"
    static let defaultCellularQuality = StreamTraits.Resolution.hd1080.rawValue

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var expensive = false

    private init() {
        #if os(iOS)
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.withLock { self.expensive = path.isExpensive }
        }
        monitor.start(queue: DispatchQueue(label: "encore.network"))
        #endif
    }

    var isExpensive: Bool { lock.withLock { expensive } }

    /// The limits to rank sources by right now, or nil for none.
    var limits: NetworkLimits? {
        #if os(iOS)
        guard isExpensive else { return nil }
        let stored = UserDefaults.standard.object(forKey: Self.cellularQualityKey) as? Int ?? Self.defaultCellularQuality
        return stored > 0 ? NetworkLimits(maxResolution: stored) : nil
        #else
        return nil
        #endif
    }
}
