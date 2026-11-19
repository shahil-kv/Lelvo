import Foundation
import LelvoCore

/// UserDefaults-backed settings. Views bind with `@AppStorage(Prefs.Key.x)`; services read `Prefs.x`.
enum Prefs {
    enum Key {
        static let onboardingComplete = "onboardingComplete"
        static let wifiOnly = "wifiOnly"
        static let photosOnMobile = "photosOnMobile"
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
        static let backgroundRuns = "backgroundRuns"
        static let runMarks = "runMarks"
        static let floodUntil = "floodUntil"
        static let firstFullBackupAt = "firstFullBackupAt"
        static let automationOfferSnoozedUntil = "automationOfferSnoozedUntil"
        static let automationOfferDismissals = "automationOfferDismissals"
        static let notifyBackups = "notifyBackups"
        static let nightTotals = "nightTotals"
        static let nightTotalsMorning = "nightTotalsMorning"
        static let reminderDueAt = "reminderDueAt"
        static let remindersSent = "remindersSent"
        static let backupPaused = "backupPaused"
        static let autoBackup = "autoBackup"
        static let autoBackupNudges = "autoBackupNudges"
        static let autoBackupNudgedAt = "autoBackupNudgedAt"
        static let streamingCopies = "streamingCopies"
        static let videoQuality = "videoQuality"
        /// Start a video again when it ends. Off by default. Only this device's preference: nothing in the library changes.
        static let loopVideos = "loopVideos"
        static let keepAwakeDuringBackup = "keepAwakeDuringBackup"
        /// The one-time "Found a bug? Tell me" note was closed, after the photos first appeared.
        static let communityNoteShown = "communityNoteShown"
        static let secondCopyBookmark = "secondCopyBookmark"
        static let secondCopyVolume = "secondCopyVolume"
        /// Debug-only Pro unlock (also used from the paywall Toggle in DEBUG builds).
        static let proDebugUnlocked = "proDebugUnlocked"
        /// Locked folder auto-lock grace after backgrounding, in milliseconds (Ente-style). Default 5 seconds.
        static let lockedFolderAutoLockMs = "lockedFolderAutoLockMs"
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
            Key.photosOnMobile: true,
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
            Key.notifyBackups: false,
            Key.streamingCopies: true,
            Key.keepAwakeDuringBackup: true,
            Key.videoQuality: VideoQualityPreference.automatic.rawValue,
            Key.loopVideos: false,
            Key.onboardingComplete: false,
            Key.lockedFolderAutoLockMs: 5_000,
        ])
    }

    static var onboardingComplete: Bool { defaults.bool(forKey: Key.onboardingComplete) }
    static var wifiOnly: Bool { defaults.bool(forKey: Key.wifiOnly) }
    static var photosOnMobile: Bool { defaults.bool(forKey: Key.photosOnMobile) }
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
    static var loopVideos: Bool { defaults.bool(forKey: Key.loopVideos) }
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
    /// The folder chosen for Keep a second copy, as a bookmark so it's found again after a drive is renamed or remounted.
    static var secondCopyBookmark: Data? {
        get { defaults.data(forKey: Key.secondCopyBookmark) }
        set { defaults.set(newValue, forKey: Key.secondCopyBookmark) }
    }
    /// The drive's name when the folder was chosen, for "connect <drive>" while it's unplugged.
    static var secondCopyVolume: String? {
        get { defaults.string(forKey: Key.secondCopyVolume) }
        set { defaults.set(newValue, forKey: Key.secondCopyVolume) }
    }
    /// Recent backup runs (newest last), kept for "Working" checks and the Background lab. Counts only.
    static var runRecords: [RunRecord] {
        guard let data = defaults.data(forKey: Key.backgroundRuns) else { return [] }
        return (try? JSONDecoder().decode([RunRecord].self, from: data)) ?? []
    }

    static func record(_ r: RunRecord) {
        let list = BackgroundRuns.appending(r, to: runRecords)
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: Key.backgroundRuns) }
    }

    private static let marksLock = NSLock()

    /// A run is going; `recordRun` clears it. See `BackgroundRuns.killedRuns`.
    static func markRunStarted(_ source: RunSource, at started: Date) {
        marksLock.withLock {
            let marks = defaults.stringArray(forKey: Key.runMarks) ?? []
            defaults.set(marks + [BackgroundRuns.mark(source, startedAt: started)], forKey: Key.runMarks)
        }
    }

    static func markRunEnded(_ source: RunSource, at started: Date) {
        marksLock.withLock {
            let mark = BackgroundRuns.mark(source, startedAt: started)
            defaults.set((defaults.stringArray(forKey: Key.runMarks) ?? []).filter { $0 != mark }, forKey: Key.runMarks)
        }
    }

    /// Once per process, before any run starts: marks left by the last process become "ended with the process" records.
    @discardableResult
    static func recordKilledRuns() -> Int {
        marksLock.withLock {
            let killed = BackgroundRuns.killedRuns(marks: defaults.stringArray(forKey: Key.runMarks) ?? [])
            defaults.removeObject(forKey: Key.runMarks)
            killed.forEach(record)
            return killed.count
        }
    }

    /// Telegram's FLOOD_WAIT end. Saved so a new process (iOS starts one for most background tasks) doesn't send
    /// before the wait is over.
    static var floodUntil: Date {
        get { Date(timeIntervalSince1970: defaults.double(forKey: Key.floodUntil)) }
        set { defaults.set(newValue.timeIntervalSince1970, forKey: Key.floodUntil) }
    }

    static var backupPaused: Bool {
        get { defaults.bool(forKey: Key.backupPaused) }
        set { defaults.set(newValue, forKey: Key.backupPaused) }
    }
    /// Milliseconds before Locked folder re-locks after backgrounding (Ente). Default 5 seconds.
    static var lockedFolderAutoLockMs: Int {
        get {
            if defaults.object(forKey: Key.lockedFolderAutoLockMs) == nil { return 5_000 }
            return max(0, defaults.integer(forKey: Key.lockedFolderAutoLockMs))
        }
        set { defaults.set(max(0, newValue), forKey: Key.lockedFolderAutoLockMs) }
    }
    static var albumMode: AlbumMode { AlbumMode(rawValue: defaults.string(forKey: Key.albumMode) ?? "") ?? .all }
    static var albumIds: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.albumIds) ?? []) }
        set { defaults.set(Array(newValue), forKey: Key.albumIds) }
    }
}
