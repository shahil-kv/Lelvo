import Foundation

/// Device-local Locked folder membership. Ids are timeline entry ids (`GalleryEntry.id`).
/// Not synced through Telegram yet (that would need a format note). Photos are never deleted — only hidden from the
/// main timeline until Face ID / passcode unlocks this folder.
@MainActor
final class LockedFolderStore: ObservableObject {
    static let shared = LockedFolderStore()
    static let didChange = Notification.Name("LockedFolderDidChange")

    @Published private(set) var ids: Set<String> = []
    /// Cleared when the app goes to the background so Locked folder needs Face ID again.
    @Published private(set) var unlockedThisSession = false

    private init() { ids = Self.load() }

    var count: Int { ids.count }
    func contains(_ id: String) -> Bool { ids.contains(id) }

    func lock(_ entryIds: [String]) {
        let next = ids.union(entryIds)
        guard next != ids else { return }
        ids = next
        persist()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func unlockItems(_ entryIds: [String]) {
        let next = ids.subtracting(entryIds)
        guard next != ids else { return }
        ids = next
        persist()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func markSessionUnlocked() { unlockedThisSession = true }

    func lockSession() { unlockedThisSession = false }

    /// Ids for the current library only (scoped so switching libraries doesn't mix folders).
    private static var storageKey: String {
        let chat = AppEnvironment.shared.library.chatId.map(String.init) ?? "none"
        return "lockedFolder.ids.\(chat)"
    }

    private func persist() {
        Prefs.defaults.set(Array(ids).sorted(), forKey: Self.storageKey)
    }

    private static func load() -> Set<String> {
        Set(Prefs.defaults.stringArray(forKey: storageKey) ?? [])
    }

    /// Call after the library chat id is known so we load the right set.
    func reloadForLibrary() {
        ids = Self.load()
        unlockedThisSession = false
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
