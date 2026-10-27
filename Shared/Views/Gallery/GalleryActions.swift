import Foundation
import Photos
import MemvoCore

/// Batch and single-item actions shared by the grid and the viewer.
enum GalleryActions {
    /// A file with the item's real name, ready for the share sheet: what Photos shows (the edit, if any), like Photos;
    /// `original`: the untouched original instead, like "Export Unmodified Original" in Photos for Mac.
    static func shareableFile(for entry: GalleryEntry, original: Bool = false) async throws -> URL {
        let env = AppEnvironment.shared
        if let asset = entry.asset {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Share-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let exported = try await env.photos.exportOriginal(of: asset, into: dir)
            if let paired = exported.pairedVideoURL { try? FileManager.default.removeItem(at: paired) }
            // Share what the user sees: the edit when there is one, like Photos.
            let edit = original ? nil : exported.editedURL
            if let other = original ? exported.editedURL : nil { try? FileManager.default.removeItem(at: other) }
            let source = edit ?? exported.primaryURL
            let named = dir.appendingPathComponent((edit != nil ? exported.editedFilename : nil)?.sanitizedFilename
                                                   ?? exported.primaryFilename.sanitizedFilename)
            try FileManager.default.moveItem(at: source, to: named)
            return named
        }
        guard let item = entry.item else { throw PhotoLibraryError.assetMissing }
        if original { return try env.media.shareableCopy(of: try await env.media.original(for: item), filename: item.filename) }
        let cached = try await env.media.displayed(for: item)
        return try env.media.shareableCopy(of: cached, filename: CloudMediaService.displayedFilename(item))
    }

    /// Puts a cloud item back into Photos as it was (`RestorePlan`): the untouched original with its edit shown and
    /// revertible, the RAW of a RAW + JPEG pair, the Live Photo's video, favourite, hidden, date, place and albums. Then
    /// links it so it isn't uploaded again. `progress` (0…1) follows the download of the original, the slow part.
    static func saveToPhotos(_ item: MediaItem, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let env = AppEnvironment.shared
        let started = Date()
        let status = PhotoLibraryService.authorizationStatus
        guard status == .authorized || status == .limited else { throw PhotoLibraryError.notAuthorized }
        let plan = RestorePlan.make(for: item)
        var files: [String: URL] = [:]
        defer { for url in files.values { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } }
        for role in plan.downloads {
            do {
                files[role] = try await env.media.restoreFile(for: item, role: role, progress: role == "o" ? progress : nil)
            } catch where role != "o" && role != "pv" {
                // An extra that can't be read only makes the restore less complete; the photo itself still comes back.
                AppLog.shared.warn("Restoring \(item.filename) without its \(role): \(error.localizedDescription)")
            }
        }
        var albums = plan.albums
        if let md = files["md"], let extra = try? ExtraMetadata.decode(Data(contentsOf: md)), let all = extra.a { albums = all }
        let took = Date().timeIntervalSince(started)
        appLog(String(format: "Downloaded %@ to save: %@ in %.0f s (%@/s)", item.filename, Format.bytes(item.fileSize), took,
                      Format.bytes(Int64(Double(item.fileSize) / max(took, 0.1)))))
        if let newId = try await env.photos.restore(item, plan: plan, files: files, albums: albums) {
            try env.store.update(id: item.id) { $0.localIdentifier = newId }
        }
    }

    /// Moves the items to Recently Deleted: hidden everywhere and no longer counted as backed up, but their
    /// messages stay in the channel for `CloudTrash.retention`, so a mistaken delete can be undone.
    static func deleteFromCloud(_ items: [MediaItem]) async throws {
        let env = AppEnvironment.shared
        for item in items {
            try env.store.update(id: item.id) { CloudTrash.trash(&$0) }
            appLog("Moved \(item.filename) to Recently Deleted")
        }
    }

    /// Recovers the items, except ones whose messages are being deleted right now. Returns how many came back.
    @discardableResult
    static func recover(_ items: [MediaItem]) throws -> Int {
        let env = AppEnvironment.shared
        var recovered = 0
        for item in items {
            // Holding the gate means a deletion can't start on this item while it's recovered, and vice versa.
            let done = try TrashGate.shared.ifNotDeleting(item.id) {
                try env.store.update(id: item.id) { CloudTrash.recover(&$0) }
            }
            if done { recovered += 1 }
        }
        appLog("Recovered \(recovered) items from Recently Deleted")
        if recovered < items.count { throw TrashError.alreadyDeleting }
        return recovered
    }

    /// Deletes every message of the trashed items (all resources and parts) from the channel. Only items still in
    /// Recently Deleted when their turn comes can go (`onlyIfExpired` for the 30-day cleanup); anything recovered
    /// meanwhile is left alone.
    static func deletePermanently(_ items: [MediaItem], onlyIfExpired: Bool = false) async throws {
        let env = AppEnvironment.shared
        guard !items.isEmpty else { return }
        if !DemoMode.isActive { try await env.td.waitUntilReady(timeout: 20) }
        for item in items {
            // Re-read under the gate: the user may have recovered it since the list was made.
            guard let current = TrashGate.shared.claim(item.id, {
                (try? env.store.item(id: item.id)).flatMap { $0.status == .trashed && (!onlyIfExpired || CloudTrash.isExpired($0)) ? $0 : nil }
            }) else { continue }
            defer { TrashGate.shared.release(item.id) }
            if !DemoMode.isActive {
                guard let chatId = env.library.chatId else { throw LibraryError.noLibrary }
                try await env.td.deleteMessages(chatId: chatId, ids: current.allMessageIds)
            }
            try env.store.delete(id: current.id)
            env.thumbnailCache.remove(CloudMediaService.thumbnailKey(current))
            appLog("Deleted \(current.filename) from cloud")
        }
    }

    /// Items in Recently Deleted, most recently deleted first.
    static func trashedItems() -> [MediaItem] {
        ((try? AppEnvironment.shared.store.items(status: .trashed)) ?? [])
            .sorted { ($0.trashedAt ?? .distantPast) > ($1.trashedAt ?? .distantPast) }
    }

    /// Deletes items whose 30 days in Recently Deleted are over. Quietly retried next time on failure.
    static func emptyExpiredTrash() async {
        let expired = trashedItems().filter { CloudTrash.isExpired($0) }
        guard !expired.isEmpty, AppEnvironment.shared.isConfigured || DemoMode.isActive else { return }
        do { try await deletePermanently(expired, onlyIfExpired: true) }
        catch { AppLog.shared.warn("Emptying Recently Deleted failed: \(error.localizedDescription)") }
    }
}

enum TrashError: LocalizedError {
    case alreadyDeleting
    var errorDescription: String? { "Some items were already being removed from your Telegram library and couldn't be recovered." }
}

/// Keeps recovering and permanently deleting the same item from overlapping (the 30-day cleanup runs in the
/// background while the user can tap Recover).
final class TrashGate: @unchecked Sendable {
    static let shared = TrashGate()
    private let lock = NSLock()
    private var deleting = Set<String>()

    /// Marks `id` as being deleted when `check` (run under the lock) returns an item; nil if it's taken or gone.
    func claim<T>(_ id: String, _ check: () -> T?) -> T? {
        lock.withLock {
            guard !deleting.contains(id), let value = check() else { return nil }
            deleting.insert(id)
            return value
        }
    }

    func release(_ id: String) { _ = lock.withLock { deleting.remove(id) } }

    /// Runs `body` unless `id` is being deleted. Returns whether it ran.
    func ifNotDeleting(_ id: String, _ body: () throws -> Void) throws -> Bool {
        try lock.withLock {
            guard !deleting.contains(id) else { return false }
            try body()
            return true
        }
    }
}
