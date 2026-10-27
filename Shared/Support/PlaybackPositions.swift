import Foundation
import MemvoCore

/// Where each long video was left, on this device only (`VideoNavigation` decides which positions count). Keyed by the
/// viewer entry id; only the most recent few hundred are kept.
enum PlaybackPositions {
    private static let key = "videoPlaybackPositions"
    private static let limit = 300
    private static let lock = NSLock()

    private struct Saved: Codable {
        var seconds: Double
        var at: Date
    }

    static func position(for id: String) -> Double? {
        lock.withLock { load()[id]?.seconds }
    }

    /// Remembers `seconds`, or forgets the video when it was watched to the end or barely started.
    static func record(_ seconds: Double, duration: Double, for id: String) {
        lock.withLock {
            var all = load()
            if VideoNavigation.shouldRemember(position: seconds, duration: duration) {
                all[id] = Saved(seconds: seconds, at: Date())
                if all.count > limit {
                    for old in all.sorted(by: { $0.value.at < $1.value.at }).prefix(all.count - limit) { all[old.key] = nil }
                }
            } else {
                guard all.removeValue(forKey: id) != nil else { return }
            }
            if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: key) }
        }
    }

    /// Caller holds `lock`.
    private static func load() -> [String: Saved] {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([String: Saved].self, from: $0) } ?? [:]
    }
}
