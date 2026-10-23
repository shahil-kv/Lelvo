import Foundation

/// UserDefaults-backed settings. Views bind with `@AppStorage(Prefs.Key.x)`; services read `Prefs.x`.
enum Prefs {
    enum Key {
        static let onboardingComplete = "onboardingComplete"
        static let wifiOnly = "wifiOnly"
        static let backupVideos = "backupVideos"
        static let includeScreenshots = "includeScreenshots"
        static let albumMode = "albumMode"
        static let albumIds = "albumIds"
        static let encryptionEnabled = "encryptionEnabled"
        static let cacheCapMB = "cacheCapMB"
        static let allowFreeUpSpace = "allowFreeUpSpace"
        static let gridColumns = "gridColumns"
        static let chatType = "chatType"
        static let chatTitle = "chatTitle"
        static let botUsername = "botUsername"
        static let lastBackupAt = "lastBackupAt"
    }

    enum AlbumMode: String, CaseIterable, Identifiable {
        case all, include, exclude
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All photos"
            case .include: return "Only selected albums"
            case .exclude: return "All except selected albums"
            }
        }
    }

    static let defaults = UserDefaults.standard

    static func registerDefaults() {
        defaults.register(defaults: [
            Key.wifiOnly: true,
            Key.backupVideos: true,
            Key.includeScreenshots: true,
            Key.albumMode: AlbumMode.all.rawValue,
            Key.encryptionEnabled: false,
            Key.cacheCapMB: 500,
            Key.allowFreeUpSpace: false,
            Key.gridColumns: 4,
            Key.onboardingComplete: false
        ])
    }

    static var onboardingComplete: Bool { defaults.bool(forKey: Key.onboardingComplete) }
    static var wifiOnly: Bool { defaults.bool(forKey: Key.wifiOnly) }
    static var backupVideos: Bool { defaults.bool(forKey: Key.backupVideos) }
    static var includeScreenshots: Bool { defaults.bool(forKey: Key.includeScreenshots) }
    static var encryptionEnabled: Bool { defaults.bool(forKey: Key.encryptionEnabled) }
    static var allowFreeUpSpace: Bool { defaults.bool(forKey: Key.allowFreeUpSpace) }
    static var cacheCapBytes: Int64 { Int64(max(50, defaults.integer(forKey: Key.cacheCapMB))) * 1024 * 1024 }
    static var albumMode: AlbumMode { AlbumMode(rawValue: defaults.string(forKey: Key.albumMode) ?? "") ?? .all }
    static var albumIds: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.albumIds) ?? []) }
        set { defaults.set(Array(newValue), forKey: Key.albumIds) }
    }
    static var chatType: String { defaults.string(forKey: Key.chatType) ?? "channel" }
    /// Telegram allows ~1 msg/s per chat, and about 20 msgs/min in groups.
    static var sendInterval: TimeInterval { chatType == "channel" ? 1.05 : 3.1 }
}
