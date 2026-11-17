import Foundation
import LelvoCore

/// Locked Folder session + local pending membership. Synced membership lives on `MediaItem.locked` via MetaLog
/// lock/unlock notes (#129). Photos are never deleted from Telegram — only hidden in Lelvo on every device.
@MainActor
final class LockedFolderStore: ObservableObject {
    static let shared = LockedFolderStore()
    static let didChange = Notification.Name("LockedFolderDidChange")

    /// Ente-compatible auto-lock choices (milliseconds). `0` = lock as soon as the app backgrounds.
    static let autoLockOptionsMs: [Int] = [0, 5_000, 15_000, 60_000, 300_000, 1_800_000]

    /// Phone-only assets not yet backed up: hidden here until a `lock` note can use their cloud id.
    @Published private(set) var pendingLocalIds: Set<String> = []
    /// Cleared when leaving Locked folder, or after the auto-lock grace on resume.
    @Published private(set) var unlockedThisSession = false
    /// Google Photos: first successful device auth marks the folder set up for this library.
    @Published private(set) var isSetUp = false
    /// Synced locked cloud item ids (from the index). Refreshed when the library or meta changes.
    @Published private(set) var syncedLockedIds: Set<String> = []

    private var backgroundedAt: Date?
    private var chatKey: String = "none"

    private init() {
        chatKey = Self.currentChatKey()
        isSetUp = Self.loadSetUp(chat: chatKey)
        pendingLocalIds = Self.loadPending(chat: chatKey)
        migrateLegacyMembershipIfNeeded()
        refreshSyncedLockedIds()
    }

    var count: Int { syncedLockedIds.count + pendingLocalIds.count }

    /// True when this timeline entry must stay out of the main library, search and memories.
    func hidesFromTimeline(_ entry: GalleryEntry) -> Bool {
        if let item = entry.item, item.locked == true { return true }
        if let id = entry.item?.id, syncedLockedIds.contains(id) { return true }
        if let local = entry.asset?.localIdentifier, pendingLocalIds.contains(local) { return true }
        if pendingLocalIds.contains(entry.id) { return true }
        return false
    }

    func containsSynced(_ itemId: String) -> Bool { syncedLockedIds.contains(itemId) }

    /// Move entries into Locked Folder. Backed-up items get a MetaLog `lock` note; phone-only wait in `pendingLocalIds`
    /// and are noted once backup finishes.
    @discardableResult
    func lockEntries(_ entries: [GalleryEntry]) -> Int {
        var cloud: [MediaItem] = []
        var pending: [String] = []
        var toBackUp: [String] = []
        for entry in entries {
            if let item = entry.item, item.status == .backedUp || item.status == .trashed {
                cloud.append(item)
            } else if let local = entry.asset?.localIdentifier {
                pending.append(local)
                if entry.item == nil || entry.item?.status != .backedUp {
                    toBackUp.append(local)
                }
            } else if let item = entry.item {
                // Uploading / queued: remember by local id when known, else by cloud id once ready.
                if let local = item.localIdentifier {
                    pending.append(local)
                }
            }
        }
        var changed = 0
        if !cloud.isEmpty {
            changed += (try? MetaSync.shared.change(cloud, key: .locked, value: true)) ?? 0
            noteLocked(cloud.map(\.id))
            refreshSyncedLockedIds()
            // Don't wait for the usual 10s favorites pacing — other devices need the lock note soon.
            Task { await MetaSync.shared.send() }
        }
        if !pending.isEmpty {
            let next = pendingLocalIds.union(pending)
            if next != pendingLocalIds {
                pendingLocalIds = next
                persistPending()
                changed += pending.count
            }
        }
        if !toBackUp.isEmpty {
            _ = AppEnvironment.shared.engine.enqueue(localIdentifiers: toBackUp)
        }
        if !isSetUp { markSetUp() }
        if changed > 0 { NotificationCenter.default.post(name: Self.didChange, object: nil) }
        return changed
    }

    /// Remove from Locked Folder. Emits MetaLog `unlock` for cloud items; clears local pending.
    @discardableResult
    func unlockEntries(_ entries: [GalleryEntry]) -> Int {
        var cloud: [MediaItem] = []
        var pending: [String] = []
        for entry in entries {
            if let item = entry.item {
                cloud.append(item)
                if let local = item.localIdentifier { pending.append(local) }
            }
            if let local = entry.asset?.localIdentifier { pending.append(local) }
            pending.append(entry.id)
        }
        var changed = 0
        if !cloud.isEmpty {
            changed += (try? MetaSync.shared.change(cloud, key: .locked, value: false)) ?? 0
            localChanges += 1
            syncedLockedIds.subtract(cloud.map(\.id))
            refreshSyncedLockedIds()
            Task { await MetaSync.shared.send() }
        }
        let next = pendingLocalIds.subtracting(pending)
        if next != pendingLocalIds {
            pendingLocalIds = next
            persistPending()
            changed += 1
        }
        if changed > 0 { NotificationCenter.default.post(name: Self.didChange, object: nil) }
        return changed
    }

    /// After a backup finishes: if the asset was pending Locked, emit the `lock` note and drop the pending id.
    func promotePendingAfterBackup(item: MediaItem) {
        guard let local = item.localIdentifier, pendingLocalIds.contains(local) else { return }
        guard item.status == .backedUp || item.status == .trashed else { return }
        _ = try? MetaSync.shared.change([item], key: .locked, value: true)
        pendingLocalIds.remove(local)
        persistPending()
        noteLocked([item.id])
        refreshSyncedLockedIds()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func markSessionUnlocked() { unlockedThisSession = true }

    func lockSession() { unlockedThisSession = false }

    func markSetUp() {
        guard !isSetUp else { return }
        isSetUp = true
        Prefs.defaults.set(true, forKey: Self.setupKey(chat: chatKey))
    }

    func noteEnteredBackground() {
        backgroundedAt = Date()
        if Prefs.lockedFolderAutoLockMs == 0 {
            lockSession()
        }
    }

    func noteBecameActive() {
        defer { backgroundedAt = nil }
        guard unlockedThisSession, let at = backgroundedAt else { return }
        let graceMs = Prefs.lockedFolderAutoLockMs
        let elapsedMs = Date().timeIntervalSince(at) * 1000
        if elapsedMs >= Double(graceMs) {
            lockSession()
        }
    }

    func reloadForLibrary() {
        chatKey = Self.currentChatKey()
        isSetUp = Self.loadSetUp(chat: chatKey)
        pendingLocalIds = Self.loadPending(chat: chatKey)
        unlockedThisSession = false
        backgroundedAt = nil
        migrateLegacyMembershipIfNeeded()
        refreshSyncedLockedIds()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Re-reads the locked ids off the main actor. It used to decode the whole library here on the main actor, on
    /// every timeline rebuild, which made a large library stutter. Posts `didChange` when the set changed.
    func refreshSyncedLockedIds() {
        Task { await reloadSyncedLockedIds() }
    }

    func reloadSyncedLockedIds() async {
        var ids: Set<String> = []
        // A lock or unlock tapped while the read runs changes the set first; read again so the older read can't undo it.
        while true {
            let started = localChanges
            ids = await Task.detached(priority: .userInitiated) {
                Set(((try? AppEnvironment.shared.store.lockedItems()) ?? []).map(\.id))
            }.value
            if started == localChanges { break }
        }
        let changed = ids != syncedLockedIds
        syncedLockedIds = ids
        markSetUpIfUsed()
        if changed { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }

    /// Locked items the timeline already holds, so a lock shows at once without reading the store.
    func noteLocked(_ ids: some Sequence<String>) {
        localChanges += 1
        let before = syncedLockedIds.count
        syncedLockedIds.formUnion(ids)
        if syncedLockedIds.count != before { markSetUpIfUsed() }
    }

    /// Counts locks and unlocks made here, so a store read that started before one is read again.
    private var localChanges = 0

    private func markSetUpIfUsed() {
        if !syncedLockedIds.isEmpty || !pendingLocalIds.isEmpty {
            isSetUp = true
            Prefs.defaults.set(true, forKey: Self.setupKey(chat: chatKey))
        }
    }

    /// Pull Locked Folder membership from the Telegram library (and re-apply notes already stored). Call when opening
    /// Locked on a second device so a lock note from iPhone/Android shows up without waiting for the 5‑minute open gap.
    /// Also re-sends a lock the channel doesn't hold yet, so a note that never left this device still reaches Mac and
    /// Android.
    func syncFromChannel() async {
        let env = AppEnvironment.shared
        guard env.isConfigured, env.library.isUnlocked, !DemoMode.isActive else {
            refreshSyncedLockedIds()
            return
        }
        // Same path as Recently Deleted / favorites: catch-up only reads *new* channel messages (and a weekly full
        // pass when due). Caption prefixes pick notes (`CGM1` / `CGT1`); photo parts are not re-downloaded. Never
        // force a full library rebuild just because Locked looks empty — that would walk every document in a big library.
        var caughtUp = false
        do {
            try await env.library.catchUp()
            caughtUp = true
        } catch {
            AppLog.shared.warn("Locked Folder catch-up failed: \(error.localizedDescription)")
        }
        // Re-apply notes already stored locally (cheap; no Telegram round trip).
        try? env.library.applyMetaNotes(only: nil)
        // Only after catching up, and only locks the channel doesn't hold yet (a note that never left this device).
        // Sent before the catch-up, every lock here overrode a newer unlock from another device, on every open.
        let missing = await Task.detached(priority: .userInitiated) { () -> [MediaItem] in
            let latest = MetaLog.latest((try? env.store.metaNotes()) ?? [])
            return ((try? env.store.lockedItems()) ?? []).filter {
                ($0.status == .backedUp || $0.status == .trashed) && latest[$0.id]?[.locked]?.value != true
            }
        }.value
        // Without a catch-up this device may not know a newer unlock: re-send nothing then.
        if caughtUp, !missing.isEmpty { _ = try? MetaSync.shared.change(missing, key: .locked, value: true) }
        await MetaSync.shared.send()
        await reloadSyncedLockedIds()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        if syncedLockedIds.isEmpty {
            appLog("Locked Folder: still empty after sync — no lock note in the Telegram library yet. Lock again on the phone.")
        } else {
            appLog("Locked Folder: \(syncedLockedIds.count) synced item(s) from the Telegram library")
        }
    }

    // MARK: - Persistence (setup + pending only; synced state is MetaLog)

    private func persistPending() {
        Prefs.defaults.set(Array(pendingLocalIds).sorted(), forKey: Self.pendingKey(chat: chatKey))
    }

    private static func loadPending(chat: String) -> Set<String> {
        Set(Prefs.defaults.stringArray(forKey: pendingKey(chat: chat)) ?? [])
    }

    private static func loadSetUp(chat: String) -> Bool {
        Prefs.defaults.bool(forKey: setupKey(chat: chat))
    }

    private static func pendingKey(chat: String) -> String { "lockedFolder.pending.\(chat)" }
    private static func setupKey(chat: String) -> String { "lockedFolder.setup.\(chat)" }
    private static func legacyKey(chat: String) -> String { "lockedFolder.ids.\(chat)" }

    private static func currentChatKey() -> String {
        AppEnvironment.shared.library.chatId.map(String.init) ?? "none"
    }

    /// One-time: Keychain/UserDefaults membership from the device-local build → MetaLog lock notes.
    private func migrateLegacyMembershipIfNeeded() {
        var legacy = Set(Prefs.defaults.stringArray(forKey: Self.legacyKey(chat: chatKey)) ?? [])
        if let data = KeychainStore.data(for: .lockedFolderIds),
           let blob = try? JSONDecoder().decode(LegacyBlob.self, from: data),
           let state = blob.libraries[chatKey] {
            legacy.formUnion(state.ids)
            if state.isSetUp { markSetUp() }
        }
        guard !legacy.isEmpty else { return }
        let store = AppEnvironment.shared.store
        var cloud: [MediaItem] = []
        var pending: [String] = []
        for id in legacy {
            if let item = try? store.item(id: id), item.status == .backedUp || item.status == .trashed {
                cloud.append(item)
            } else if let item = try? store.item(localIdentifier: id), item.status == .backedUp || item.status == .trashed {
                cloud.append(item)
            } else {
                pending.append(id)
            }
        }
        if !cloud.isEmpty {
            _ = try? MetaSync.shared.change(cloud, key: .locked, value: true)
        }
        if !pending.isEmpty {
            pendingLocalIds.formUnion(pending)
            persistPending()
        }
        Prefs.defaults.removeObject(forKey: Self.legacyKey(chat: chatKey))
        // Drop this library from the Keychain blob; keep other libraries until their reload migrates them.
        if var blob = try? JSONDecoder().decode(LegacyBlob.self, from: KeychainStore.data(for: .lockedFolderIds) ?? Data()),
           blob.libraries[chatKey] != nil {
            blob.libraries[chatKey] = nil
            if blob.libraries.isEmpty {
                _ = KeychainStore.set(nil as Data?, for: .lockedFolderIds)
            } else if let data = try? JSONEncoder().encode(blob) {
                _ = KeychainStore.set(data, for: .lockedFolderIds)
            }
        }
        markSetUp()
    }

    private struct LegacyBlob: Codable {
        var libraries: [String: LegacyState]
    }
    private struct LegacyState: Codable {
        var ids: [String]
        var isSetUp: Bool
    }
}
