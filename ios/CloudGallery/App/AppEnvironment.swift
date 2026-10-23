import Foundation
import CloudGalleryCore

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

    private init() {
        Prefs.registerDefaults()
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        stagingDirectory = support.appendingPathComponent("Staging", isDirectory: true)
        try? fm.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var stagingURL = stagingDirectory
        try? stagingURL.setResourceValues(excluded)

        store = LibraryStore.openOrFallback(url: support.appendingPathComponent("Library.sqlite"))
        thumbnailCache = LRUDiskCache(directory: caches.appendingPathComponent("Thumbnails"), capacity: Prefs.thumbnailCacheBytes)
        originalsCache = LRUDiskCache(directory: caches.appendingPathComponent("Originals"), capacity: Prefs.mediaCacheBytes)

        library = LibraryService(td: td, store: store)
        reader = MediaReader(td: td, library: library)
        uploader = CloudUploader(td: td, library: library, staging: stagingDirectory)
        engine = BackupEngine(environment: self)
        media = CloudMediaService(environment: self)
        freeUpSpace = FreeUpSpaceService(environment: self)
    }

    /// Signed in to Telegram, library chosen and (if encrypted) unlocked.
    var isConfigured: Bool { TDCredentials.load() != nil && library.isConfigured && library.isUnlocked }

    /// Trims every cache to its cap, including TDLib's own file cache.
    func enforceCacheLimits() async {
        thumbnailCache.setCapacity(Prefs.thumbnailCacheBytes)
        originalsCache.setCapacity(Prefs.mediaCacheBytes)
        if td.isReady { await td.optimizeStorage(maxBytes: Prefs.mediaCacheBytes) }
    }

    /// Moves to another library channel: stops the backup, clears the local index (it belongs to the old
    /// library), restores the chosen one from Telegram and re-links this iPhone's photos to it.
    func switchLibrary(to chatId: Int64, passphrase: String?) async throws {
        engine.pause()
        for _ in 0..<40 where engine.isRunning { try? await Task.sleep(nanoseconds: 250_000_000) }
        try store.deleteAll()
        reader.forgetCaches()
        library.forget()
        let header = try await library.useExisting(chatId: chatId)
        if header.encrypted {
            guard let passphrase, !passphrase.isEmpty else { throw LibraryError.locked }
            try library.unlock(passphrase: passphrase)
        }
        let summary = try await library.scan(full: true)
        let linked = engine.relinkRestoredItems()
        appLog("Switched library: \(summary.items) items, \(linked) linked to this iPhone")
    }

    /// Wipes local state (sign out / reset). The Telegram channel is not touched.
    func resetEverything() async {
        await td.logOut()
        await td.destroyLocalData()
        try? store.deleteAll()
        thumbnailCache.clear()
        originalsCache.clear()
        library.forget()
        reader.forgetCaches()
        try? FileManager.default.removeItem(at: stagingDirectory)
        try? FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        KeychainStore.wipe()
        for key in [Prefs.Key.onboardingComplete, Prefs.Key.lastBackupAt] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
