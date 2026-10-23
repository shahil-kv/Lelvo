import Foundation
import CryptoKit
import CloudGalleryCore

/// Process-wide services, shared by the UI, background URLSession callbacks, BGTasks and App Intents.
final class AppEnvironment: @unchecked Sendable {
    static let shared = AppEnvironment()

    let store: LibraryStore
    let thumbnailCache: LRUDiskCache
    let originalsCache: LRUDiskCache
    let photos = PhotoLibraryService()
    let limiter: RateLimiter
    // Created eagerly at the end of init so access from any thread is safe.
    private(set) var uploader: BackgroundUploader!
    private(set) var engine: BackupEngine!
    private(set) var indexSync: IndexSyncService!
    private(set) var media: CloudMediaService!
    private(set) var freeUpSpace: FreeUpSpaceService!

    let stagingDirectory: URL

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

        do {
            store = try LibraryStore(url: support.appendingPathComponent("Library.sqlite"))
        } catch {
            AppLog.shared.error("Opening database failed: \(error). Falling back to in-memory store.")
            store = try! LibraryStore(url: nil)
        }
        thumbnailCache = LRUDiskCache(directory: caches.appendingPathComponent("Thumbnails"), capacity: 400 * 1024 * 1024)
        originalsCache = LRUDiskCache(directory: caches.appendingPathComponent("Originals"), capacity: Prefs.cacheCapBytes)
        limiter = RateLimiter(minInterval: Prefs.sendInterval)

        uploader = BackgroundUploader(environment: self)
        engine = BackupEngine(environment: self)
        indexSync = IndexSyncService(environment: self)
        media = CloudMediaService(environment: self)
        freeUpSpace = FreeUpSpaceService(environment: self)
    }

    // MARK: - Credentials

    var token: String? { KeychainStore.string(for: .botToken) }
    var chatId: String? { KeychainStore.string(for: .chatId) }
    var passphrase: String? { KeychainStore.string(for: .passphrase) }
    var isConfigured: Bool { token != nil && chatId != nil && passphrase != nil }

    func client(token overrideToken: String? = nil) -> TelegramClient? {
        guard let t = overrideToken ?? token else { return nil }
        return TelegramClient(token: t, limiter: limiter)
    }

    /// Generates (once) the salt used to derive the end-to-end file key from the passphrase.
    func ensureFileKeySalt() -> Data {
        if let salt = KeychainStore.data(for: .fileKeySalt) { return salt }
        let salt = KeyDerivation.randomSalt()
        KeychainStore.set(salt, for: .fileKeySalt)
        return salt
    }

    private let keyLock = NSLock()

    /// E2E master key = PBKDF2(passphrase, fileKeySalt). Cached in the Keychain so background work
    /// does not re-run 250k PBKDF2 iterations for every file.
    func fileMasterKey() throws -> SymmetricKey {
        keyLock.lock(); defer { keyLock.unlock() }
        if let raw = KeychainStore.data(for: .fileMasterKey), raw.count == 32 { return SymmetricKey(data: raw) }
        guard let passphrase else { throw CryptoError.derivationFailed }
        let raw = try KeyDerivation.pbkdf2(passphrase: passphrase, salt: ensureFileKeySalt())
        KeychainStore.set(raw, for: .fileMasterKey)
        return SymmetricKey(data: raw)
    }

    /// Wipes all local state (account switch / reset). Cloud data is untouched.
    func resetEverything() {
        try? store.deleteAll()
        thumbnailCache.clear()
        originalsCache.clear()
        try? FileManager.default.removeItem(at: stagingDirectory)
        try? FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        uploader.cancelAll()
        KeychainStore.wipe()
        UserDefaults.standard.removeObject(forKey: Prefs.Key.onboardingComplete)
        UserDefaults.standard.removeObject(forKey: Prefs.Key.chatTitle)
        UserDefaults.standard.removeObject(forKey: Prefs.Key.botUsername)
        UserDefaults.standard.removeObject(forKey: Prefs.Key.lastBackupAt)
    }
}
