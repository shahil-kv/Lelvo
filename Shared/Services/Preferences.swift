import Foundation
import LelvoCore

/// UserDefaults-backed settings. Views bind with `@AppStorage(Prefs.Key.x)`; services read `Prefs.x`.
enum Prefs {
    enum Key {
        static let onboardingComplete = "onboardingComplete"
        static let wifiOnly = "wifiOnly"
        static let backupVideos = "backupVideos"
        static let includeScreenshots = "includeScreenshots"
        static let includeHidden = "includeHidden"
        static let albumMode = "albumMode"
        static let albumIds = "albumIds"
        static let encryptionEnabled = "encryptionEnabled"
        static let cacheCapMB = "cacheCapMB"
        static let thumbnailCacheMB = "thumbnailCacheMB"
        static let mediaFilter = "mediaFilter"
        static let dateFromEnabled = "dateFromEnabled"
        static let dateFrom = "dateFrom"
        static let chargingOnly = "chargingOnly"
        static let allowFreeUpSpace = "allowFreeUpSpace"
        static let gridColumns = "gridColumns"
        static let chatType = "chatType"
        static let chatTitle = "chatTitle"
        static let botUsername = "botUsername"
        static let lastBackupAt = "lastBackupAt"
        static let backupPaused = "backupPaused"
        static let autoBackup = "autoBackup"
        static let streamingCopies = "streamingCopies"
        static let videoQuality = "videoQuality"
        static let keepAwakeDuringBackup = "keepAwakeDuringBackup"
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

    enum MediaFilter: String, CaseIterable, Identifiable {
        case all, photos, videos
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "Photos and videos"
            case .photos: return "Photos only"
            case .videos: return "Videos only"
            }
        }
    }

    static let defaults = UserDefaults.standard

    static func registerDefaults() {
        defaults.register(defaults: [
            Key.wifiOnly: true,
            Key.backupVideos: true,
            Key.includeScreenshots: true,
            Key.includeHidden: false,
            Key.albumMode: AlbumMode.all.rawValue,
            Key.encryptionEnabled: false,
            Key.cacheCapMB: 1000,
            Key.thumbnailCacheMB: 300,
            Key.mediaFilter: MediaFilter.all.rawValue,
            Key.dateFromEnabled: false,
            Key.chargingOnly: false,
            Key.allowFreeUpSpace: false,
            Key.gridColumns: 4,
            Key.autoBackup: false,
            Key.streamingCopies: true,
            Key.keepAwakeDuringBackup: true,
            Key.videoQuality: VideoQualityPreference.automatic.rawValue,
            Key.onboardingComplete: false
        ])
    }

    static var onboardingComplete: Bool { defaults.bool(forKey: Key.onboardingComplete) }
    static var wifiOnly: Bool { defaults.bool(forKey: Key.wifiOnly) }
    static var backupVideos: Bool { defaults.bool(forKey: Key.backupVideos) }
    static var includeScreenshots: Bool { defaults.bool(forKey: Key.includeScreenshots) }
    /// Back up photos hidden in Photos too. They're never shown in Lelvo and come back hidden.
    static var includeHidden: Bool { defaults.bool(forKey: Key.includeHidden) }
    static var encryptionEnabled: Bool { defaults.bool(forKey: Key.encryptionEnabled) }
    static var allowFreeUpSpace: Bool { defaults.bool(forKey: Key.allowFreeUpSpace) }
    /// Viewed full-size media and video segments (default 1 GB).
    static var mediaCacheBytes: Int64 { Int64(max(100, defaults.integer(forKey: Key.cacheCapMB))) * 1024 * 1024 }
    static var thumbnailCacheBytes: Int64 { Int64(max(50, defaults.integer(forKey: Key.thumbnailCacheMB))) * 1024 * 1024 }
    static var mediaFilter: MediaFilter { MediaFilter(rawValue: defaults.string(forKey: Key.mediaFilter) ?? "") ?? .all }
    static var chargingOnly: Bool { defaults.bool(forKey: Key.chargingOnly) }
    /// Off (default): nothing is queued on its own. "Back up now" queues everything not yet in the cloud;
    /// "Back up" on chosen photos queues just those.
    static var autoBackup: Bool { defaults.bool(forKey: Key.autoBackup) }
    /// Make a small fast version of each video while backing it up, so it plays at once from the cloud (role `sp`).
    static var streamingCopies: Bool { defaults.bool(forKey: Key.streamingCopies) }
    static var videoQuality: VideoQualityPreference {
        VideoQualityPreference(rawValue: defaults.string(forKey: Key.videoQuality) ?? "") ?? .automatic
    }
    /// Only back up items taken on/after this date, when enabled.
    static var dateFrom: Date? {
        guard defaults.bool(forKey: Key.dateFromEnabled) else { return nil }
        let t = defaults.double(forKey: Key.dateFrom)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
    /// Set by the Pause button; automatic runs (Shortcuts, overnight) respect it until the user resumes.
    static var backupPaused: Bool {
        get { defaults.bool(forKey: Key.backupPaused) }
        set { defaults.set(newValue, forKey: Key.backupPaused) }
    }
    static var albumMode: AlbumMode { AlbumMode(rawValue: defaults.string(forKey: Key.albumMode) ?? "") ?? .all }
    static var albumIds: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.albumIds) ?? []) }
        set { defaults.set(Array(newValue), forKey: Key.albumIds) }
    }
}
