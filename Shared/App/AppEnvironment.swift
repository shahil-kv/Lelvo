import Foundation
import LelvoCore

/// Process-wide services, shared by the UI, BGTasks and App Intents.
final class AppEnvironment: @unchecked Sendable {
    static let shared = AppEnvironment()

    let store: LibraryStore
    let thumbnailCache: LRUDiskCache
    let originalsCache: LRUDiskCache
    let photos = PhotoLibraryService()
    let td = TDService.shared
    let stagingDirectory: URL

    // Created at the end of init so access from any thread is safe.
    private(set) var library: LibraryService!
    private(set) var reader: MediaReader!
    private(set) var uploader: CloudUploader!
    private(set) var engine: BackupEngine!
    private(set) var media: CloudMediaService!
    private(set) var freeUpSpace: FreeUpSpaceService!
    private(set) var similar: SimilarPhotosService!
    private(set) var search: SearchService!
    private(set) var secondCopy: SecondCopyService!

    private init() {
        Prefs.registerDefaults()
        let fm = FileManager.default
        let support = AppPaths.support
        let caches = AppPaths.caches
        stagingDirectory = support.appendingPathComponent("Staging", isDirectory: true)
        try? fm.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var stagingURL = stagingDirectory
        try? stagingURL.setResourceValues(excluded)

        store = LibraryStore.openOrFallback(url: support.appendingPathComponent("Library.sqlite"))
        // The index is rebuilt from Telegram after a restore; keep its file names and locations out of device backups.
        for name in ["Library.sqlite", "Library.sqlite-wal", "Library.sqlite-shm"] {
            var url = support.appendingPathComponent(name)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        thumbnailCache = LRUDiskCache(directory: caches.appendingPathComponent("Thumbnails"), capacity: Prefs.thumbnailCacheBytes)
        originalsCache = LRUDiskCache(directory: caches.appendingPathComponent("Originals"), capacity: Prefs.mediaCacheBytes)

        library = LibraryService(td: td, store: store)
        reader = MediaReader(td: td, library: library)
        uploader = CloudUploader(td: td, library: library, staging: stagingDirectory)
        engine = BackupEngine(environment: self)
        uploader.beforeSend = { [engine = engine!] in try await engine.waitBeforeSending() }
        media = CloudMediaService(environment: self)
        freeUpSpace = FreeUpSpaceService(environment: self)
        similar = SimilarPhotosService(photos: photos, store: store, media: { [unowned self] in self.media })
        search = SearchService(store: store, photos: photos, media: { [unowned self] in self.media })
        secondCopy = SecondCopyService(environment: self)
    }

    /// Signed in to Telegram, library chosen and (if encrypted) unlocked.
    var isConfigured: Bool { TDCredentials.load() != nil && library.isConfigured && library.isUnlocked }

    /// Trims every cache to its cap, including TDLib's own file cache.
    func enforceCacheLimits() async {
        thumbnailCache.setCapacity(Prefs.thumbnailCacheBytes)
        originalsCache.setCapacity(Prefs.mediaCacheBytes)
        if td.isReady { await td.optimizeStorage(maxBytes: Prefs.mediaCacheBytes) }
        await Task.detached(priority: .utility) { Self.removeOldShareCopies() }.value
    }

    /// Sharing copies the whole file so it carries its real name, and the system can't say when the share ended. A
    /// few big videos would otherwise sit in temporary storage. A day leaves any share in progress alone.
    private static func removeOldShareCopies(olderThan age: TimeInterval = 24 * 60 * 60) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let found = (try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: keys)) ?? []
        for url in found where url.lastPathComponent.hasPrefix("Share-") {
            let date = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate
            if let date, Date().timeIntervalSince(date) > age { try? fm.removeItem(at: url) }
        }
    }

    /// Moves to another library channel: stops the backup, swaps the local index for the chosen library's, and
    /// re-links this device's photos to it. A library opened before on this device switches instantly from its
    /// saved index while Telegram is re-scanned in the background; a new one is scanned first (a few seconds).
    func switchLibrary(to chatId: Int64, passphrase: String?) async throws {
        let t0 = Date()
        func lap(_ step: String) { appLog(String(format: "Switch timing: %@ at %.2f s", step, Date().timeIntervalSince(t0))) }
        engine.pause()
        for _ in 0..<40 where engine.isRunning { try? await Task.sleep(nanoseconds: 250_000_000) }
        if let current = library.chatId { LibrarySnapshots.save(chatId: current, items: (try? store.allItems()) ?? []) }
        lap("backup paused, current index saved")
        await TrashSync.shared.sendBeforeLeaving()
        await MetaSync.shared.sendBeforeLeaving()
        let previousChat = library.chatId
        if let previousChat { LibrarySnapshots.saveChoices(chatId: previousChat, store: store) }
        reader.forgetCaches()
        library.forget()
        let header: LibraryHeader
        do {
            header = try await library.useExisting(chatId: chatId)
            if header.encrypted {
                guard let passphrase, !passphrase.isEmpty else { throw LibraryError.locked }
                try await library.unlock(secret: passphrase)
            }
        } catch {
            // Wrong passphrase or unreachable: stay on the library we were on.
            if let previousChat { _ = try? await library.useExisting(chatId: previousChat) }
            throw error
        }
        lap("header read")
        try store.deleteAll()
        if LibrarySnapshots.restoreChoices(chatId: chatId, store: store) { TrashSync.shared.schedule() }
        if let saved = LibrarySnapshots.load(chatId: chatId), !saved.isEmpty {
            try store.upsert(saved)
            lap("saved index restored (\(saved.count) items)")
            Task.detached(priority: .utility) { [self] in
                let summary = try? await library.scan(full: true)
                let linked = engine.relinkRestoredItems()
                appLog("Switched library (background re-scan): \(summary?.items ?? -1) items, \(linked) linked to this \(Device.name)")
            }
            return
        }
        let summary = try await library.scan(full: true)
        lap("scanned")
        appLog("Switched library: \(summary.items) items")
        Task.detached(priority: .utility) { [self] in
            let linked = engine.relinkRestoredItems()
            if linked > 0 { appLog("Linked \(linked) restored items to this \(Device.name)") }
        }
    }

    /// Creates a new, empty library and makes it the current one (the local index of the old one is cleared;
    /// both libraries stay in Telegram).
    /// Returns the new library's recovery key (encrypted libraries), to show once.
    func createLibraryAndSwitch(title: String, passphrase: String?) async throws -> RecoveryKey? {
        engine.pause()
        for _ in 0..<40 where engine.isRunning { try? await Task.sleep(nanoseconds: 250_000_000) }
        await TrashSync.shared.sendBeforeLeaving()
        await MetaSync.shared.sendBeforeLeaving()
        if let current = library.chatId { LibrarySnapshots.saveChoices(chatId: current, store: store) }
        try store.deleteAll()
        reader.forgetCaches()
        library.forget()
        let created = try await library.createLibrary(title: title, passphrase: passphrase)
        appLog("Created and switched to a new library")
        return created.recoveryKey
    }

    /// Wipes local state (sign out / reset). The Telegram channel is not touched.
    /// `keepingChoices`: the user didn't ask for this (the session ended elsewhere), so signing in to the same library
    /// again must not undo their deletes.
    func resetEverything(keepingChoices: Bool = false) async {
        appLog("Reset this \(Device.name): signing out and removing Lelvo's local data")
        DemoMode.exit()
        // Stop uploads before the session goes; the paused flag is wiped with the other settings below.
        engine.pause()
        // The second copy's folder isn't touched; only the setting goes, with the others below.
        secondCopy.cancelRun()
        await TrashSync.shared.sendBeforeLeaving()
        await MetaSync.shared.sendBeforeLeaving()
        if keepingChoices, let current = library.chatId { LibrarySnapshots.saveChoices(chatId: current, store: store) }
        await td.logOut()
        await td.destroyLocalData()
        try? store.deleteAll()
        thumbnailCache.clear()
        originalsCache.clear()
        library.forget()
        reader.forgetCaches()
        try? FileManager.default.removeItem(at: stagingDirectory)
        try? FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let kept = KeychainStore.wipe()
        LibrarySnapshots.removeAll(keepingChoices: keepingChoices)
        // Every setting, not a list of them: anything left made the next start skip sign-in steps.
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        if kept.isEmpty {
            appLog("Reset finished")
        } else {
            // Stored by another build of the app; they're no longer used (see LibraryService.keys).
            AppLog.shared.warn("Reset finished; the Keychain didn't let go of: \(kept.map(\.rawValue).joined(separator: ", "))")
        }
    }
}

/// Each library's local index, saved when switching away, so switching back shows everything at once.
/// Contains the same metadata as Library.sqlite (names, dates, Telegram ids), never photo contents.
enum LibrarySnapshots {
    private static var directory: URL {
        let dir = AppPaths.support.appendingPathComponent("Libraries", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var url = dir
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        return dir
    }

    private static func url(_ chatId: Int64) -> URL { directory.appendingPathComponent("\(chatId).json") }

    static func save(chatId: Int64, items: [MediaItem]) {
        // Only what's in the cloud belongs to the library (Recently Deleted included); queued uploads stay with the
        // device's backup queue.
        let cloud = items.filter { $0.status == .backedUp || $0.status == .trashed }
        guard !cloud.isEmpty, let data = try? JSONEncoder().encode(cloud) else { return }
        try? data.write(to: url(chatId), options: .atomic)
    }

    static func load(chatId: Int64) -> [MediaItem]? {
        guard let data = try? Data(contentsOf: url(chatId)) else { return nil }
        return try? JSONDecoder().decode([MediaItem].self, from: data)
    }

    /// What only this device knows about a library and the index can't rebuild from the channel: photos deleted from the
    /// backup on purpose, and changes not sent yet. A lost recover would let an older delete note put the photo back.
    private struct Choices: Codable {
        var offBackup: [String]
        var waiting: [String: [String]]
    }

    private static let choicesPrefix = "choices-"
    private static func choicesURL(_ chatId: Int64) -> URL { directory.appendingPathComponent("\(choicesPrefix)\(chatId).json") }

    static func saveChoices(chatId: Int64, store: LibraryStore) {
        guard let offBackup = try? store.offBackupKeys(), let waiting = try? store.queuedTrashChanges(chatId: chatId) else { return }
        guard !offBackup.isEmpty || !waiting.isEmpty else {
            try? FileManager.default.removeItem(at: choicesURL(chatId))
            return
        }
        let choices = Choices(offBackup: offBackup, waiting: Dictionary(uniqueKeysWithValues: waiting.map { ($0.key.rawValue, $0.value) }))
        guard let data = try? JSONEncoder().encode(choices) else { return }
        try? data.write(to: choicesURL(chatId), options: .atomic)
    }

    /// Returns whether changes are waiting to be sent.
    @discardableResult
    static func restoreChoices(chatId: Int64, store: LibraryStore) -> Bool {
        guard let data = try? Data(contentsOf: choicesURL(chatId)), let choices = try? JSONDecoder().decode(Choices.self, from: data) else { return false }
        try? store.restoreOffBackupKeys(choices.offBackup)
        var waiting = false
        for (op, ids) in choices.waiting {
            guard let op = TrashLog.Op(rawValue: op), !ids.isEmpty, (try? store.queueTrashChange(op, itemIds: ids, chatId: chatId)) != nil else { continue }
            waiting = true
        }
        return waiting
    }

    static func removeAll(keepingChoices: Bool = false) {
        guard keepingChoices else { try? FileManager.default.removeItem(at: directory); return }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where !file.lastPathComponent.hasPrefix(choicesPrefix) { try? FileManager.default.removeItem(at: file) }
    }
}
