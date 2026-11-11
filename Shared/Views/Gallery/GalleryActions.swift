import Foundation
import Photos
import LelvoCore

/// Batch and single-item actions shared by the grid and the viewer.
enum GalleryActions {
    /// A file with the item's real name, ready for the share sheet: what Photos shows (the edit, if any), like Photos;
    /// `original`: the untouched original instead, like "Export Unmodified Original" in Photos for Mac.
    static func shareableFile(for entry: GalleryEntry, original: Bool = false, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
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
        if original { return try env.media.shareableCopy(of: try await env.media.original(for: item, progress: progress), filename: item.filename) }
        let cached = try await env.media.displayed(for: item, progress: progress)
        return try env.media.shareableCopy(of: cached, filename: CloudMediaService.displayedFilename(item))
    }

    /// Puts a cloud item back into Photos as it was (`RestorePlan`): the untouched original with its edit shown and
    /// revertible, the RAW of a RAW + JPEG pair, the Live Photo's video, favourite, hidden, date, place and albums. Then
    /// links it so it isn't uploaded again. `progress` (0…1) follows the download of the original, the slow part.
    /// Returns the new asset's local identifier.
    @discardableResult
    static func saveToPhotos(_ item: MediaItem, progress: (@Sendable (Double) -> Void)? = nil) async throws -> String? {
        let env = AppEnvironment.shared
        let started = Date()
        let status = PhotoLibraryService.authorizationStatus
        guard status == .authorized || status == .limited else { throw PhotoLibraryError.notAuthorized }
        let plan = RestorePlan.make(for: item)
        var files: [String: URL] = [:]
        defer { for url in files.values { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } }
        for role in plan.downloads {
            try Task.checkCancellation()
            do {
                files[role] = try await env.media.restoreFile(for: item, role: role, progress: role == "o" ? progress : nil)
            } catch where role != "o" && role != "pv" {
                // An extra that can't be read only makes the restore less complete; the photo itself still comes back.
                AppLog.shared.warn("Restoring \(item.filename) without its \(role): \(error.localizedDescription)")
            }
        }
        try Task.checkCancellation()
        var albums = plan.albums
        if let md = files["md"], let extra = try? ExtraMetadata.decode(Data(contentsOf: md)), let all = extra.a {
            // The full list from the backup, then every change made since (§7.3) on top, as the item already has.
            var copy = item
            copy.albums = all
            let latest = MetaLog.latest((try? env.store.metaNotes()) ?? [])
            let waiting = env.library.chatId.flatMap { try? env.store.queuedMetaChanges(chatId: $0)[item.id] }
            MetaLog.apply(MetaLog.values(for: item.id, latest: latest, waiting: waiting), to: &copy)
            albums = copy.albums ?? []
        }
        let took = Date().timeIntervalSince(started)
        appLog(String(format: "Downloaded %@ to save: %@ in %.0f s (%@/s)", item.filename, Format.bytes(item.fileSize), took,
                      Format.bytes(Int64(Double(item.fileSize) / max(took, 0.1)))))
        let newId = try await env.photos.restore(item, plan: plan, files: files, albums: albums)
        if let newId { try env.store.update(id: item.id) { $0.localIdentifier = newId } }
        return newId
    }

    /// Adds the entries to an album. Items on this device go into the album in Photos at once; items in the Telegram
    /// library get it there too (a note, docs/CLOUD_FORMAT.md §7.3), so every device shows it and saving one to Photos
    /// puts it in the album. Nothing is downloaded: an item only in the Telegram library stays there.
    static func addToAlbum(_ entries: [GalleryEntry], albumId: String, title: String) async throws -> (added: Int, failed: Int) {
        let env = AppEnvironment.shared
        let onDevice = entries.compactMap { $0.asset?.localIdentifier }
        try await env.photos.add(onDevice, toAlbum: albumId)
        if let name = MetaLog.albumName(title) {
            try MetaSync.shared.change(entries.compactMap(\.item), key: .album(name), value: true)
        }
        await MainActor.run { NotificationCenter.default.post(name: .albumsChanged, object: nil) }
        let cloudOnly = entries.filter(\.isCloudOnly)
        let cloudRecorded = cloudOnly.filter { $0.item?.status == .backedUp || $0.item?.status == .trashed }.count
        return (onDevice.count + cloudRecorded, cloudOnly.count - cloudRecorded)
    }

    /// Deletes an album everywhere, like Delete Album in Photos: the album goes from Photos on this device and, through
    /// a note, from every device's Lelvo. No photo is deleted, from the device or the Telegram library.
    static func deleteAlbum(_ title: String) async throws {
        let env = AppEnvironment.shared
        // Photos first: if the user cancels its confirmation, nothing changes anywhere.
        _ = try await env.photos.deleteAlbums(titled: title)
        if let name = MetaLog.albumName(title) {
            let members = try env.store.allItems().filter { $0.albums?.contains(name) == true }
            try MetaSync.shared.change(members, key: .album(name), value: false)
        }
        appLog("Deleted an album; its photos stay")
        await MainActor.run { NotificationCenter.default.post(name: .albumsChanged, object: nil) }
    }

    /// Marks the entries as favorites, or not. Items on this device change in Photos at once; items in the Telegram
    /// library get a note, so every device follows and saving one to Photos keeps it a favorite.
    static func setFavorite(_ entries: [GalleryEntry], _ favorite: Bool) async throws {
        let env = AppEnvironment.shared
        let onDevice = entries.compactMap { $0.asset?.localIdentifier }
        if !onDevice.isEmpty { try await env.photos.setFavorite(onDevice, favorite) }
        try MetaSync.shared.change(entries.compactMap(\.item), key: .favorite, value: favorite)
    }

    /// Whether every entry is a favorite, on this device or in the Telegram library.
    static func allFavorite(_ entries: [GalleryEntry]) -> Bool {
        !entries.isEmpty && entries.allSatisfy(\.isFavorite)
    }

    /// Removes the entries from this device and moves their backups to Recently Deleted (kept 30 days). The device
    /// copies go first, through the system's own confirmation: if the user cancels it, nothing is deleted anywhere.
    static func deleteEverywhere(_ entries: [GalleryEntry]) async throws -> (device: Int, cloud: Int) {
        let deviceIds = entries.compactMap { $0.asset?.localIdentifier }
        if !deviceIds.isEmpty { try await AppEnvironment.shared.photos.deleteAssets(deviceIds) }
        let cloud = entries.compactMap(\.item).filter { $0.status == .backedUp }
        if !cloud.isEmpty { try await deleteFromCloud(cloud) }
        return (deviceIds.count, cloud.count)
    }

    /// Moves the items to Recently Deleted: hidden everywhere and no longer counted as backed up, but their
    /// messages stay in the channel for `CloudTrash.retention`, so a mistaken delete can be undone.
    static func deleteFromCloud(_ items: [MediaItem]) async throws {
        let env = AppEnvironment.shared
        let telegram = await env.td.telegramTime()
        logClockGap(telegram)
        let deletedAt = CloudTrash.deletedAt(device: Date(), telegram: telegram)
        var moved = 0
        for item in items {
            guard try env.store.changeTrashState(id: item.id, op: .delete, chatId: TrashSync.shared.noteChatId, { CloudTrash.trash(&$0, now: deletedAt) })?.status == .trashed else { continue }
            moved += 1
            appLog("Moved \(item.filename) to Recently Deleted")
        }
        if moved > 0 { TrashSync.shared.schedule() }
    }

    /// How far this device's clock is from Telegram's: explains a wrong "days left", and shows the clock check works.
    private static func logClockGap(_ telegram: Date?) {
        guard let telegram else { appLog("Telegram's time isn't known yet"); return }
        appLog("Telegram's time differs from this device by \(Int(Date().timeIntervalSince(telegram))) s")
    }

    /// Recovers the items, except ones whose messages are being deleted right now or are already gone. Needs a connection:
    /// another device may have deleted them for good, and only Telegram can tell. Returns how many came back.
    @discardableResult
    static func recover(_ items: [MediaItem]) async throws -> Int {
        let env = AppEnvironment.shared
        if !DemoMode.isActive {
            guard await env.td.telegramTime(timeout: 10) != nil else { throw TrashError.needsConnection }
            // A connection lost from here on could wait for ever, with the screen busy.
            do { try await withDeadline(seconds: 120) { try await env.library.catchUp() } } catch { throw TrashError.needsConnection }
        }
        var recovered = 0, gone = 0, busy = 0
        var back = 0
        let current = try items.compactMap { try env.store.item(id: $0.id) }
        gone += items.count - current.count
        // Recovered on another device in the meantime.
        recovered += current.filter { $0.status != .trashed }.count
        let trashed = current.filter { $0.status == .trashed }
        var inChannel = Set<Int64>()
        if !DemoMode.isActive {
            // Without a library nothing is known about these messages, which mustn't read as "they're gone".
            guard let chatId = env.library.chatId else { throw TrashError.needsConnection }
            let ids = trashed.flatMap(\.allMessageIds)
            do { inChannel = try await withDeadline(seconds: 120) { try await env.td.existingMessages(chatId: chatId, ids: ids) } }
            catch { throw TrashError.needsConnection }
        }
        let noteChat = TrashSync.shared.noteChatId
        for item in trashed {
            if !DemoMode.isActive, TrashLog.allMessagesGone(item, existing: inChannel) {
                try env.store.forgetDeletedItem(item)
                gone += 1
                continue
            }
            // Holding the gate means a deletion can't start on this item while it's recovered, and vice versa.
            let done = try TrashGate.shared.ifNotDeleting(item.id) {
                try env.store.changeTrashState(id: item.id, op: .recover, chatId: noteChat) { CloudTrash.recover(&$0) }
            }
            if done {
                back += 1
                recovered += 1
            } else {
                busy += 1
            }
        }
        if back > 0 { TrashSync.shared.schedule() }
        appLog("Recovered \(recovered) items from Recently Deleted, \(gone) were already gone")
        if gone > 0 { throw TrashError.alreadyGone(gone) }
        if busy > 0 { throw TrashError.alreadyDeleting }
        return recovered
    }

    /// Deletes every message of the trashed items (all resources and parts) from the channel. Only items still in
    /// Recently Deleted when their turn comes can go (`expiredBy` for the 30-day cleanup: only items expired at that
    /// time); anything recovered meanwhile is left alone. Goes in batches, paced like uploads.
    static func deletePermanently(_ items: [MediaItem], expiredBy: Date? = nil) async throws {
        let env = AppEnvironment.shared
        guard !items.isEmpty else { return }
        if !DemoMode.isActive { try await env.td.waitUntilReady(timeout: 20) }
        for (index, batch) in CloudTrash.deleteBatches(items).enumerated() {
            if index > 0, !DemoMode.isActive { try await Task.sleep(nanoseconds: UInt64(BackupEngine.uploadSpacing * 1_000_000_000)) }
            while true {
                do {
                    try await deleteBatch(batch, expiredBy: expiredBy)
                    break
                } catch {
                    // The gate is released while waiting, so Recover still works, and the batch is checked again afterwards.
                    guard case .floodWait(let seconds)? = (error as? TDServiceError)?.kind else { throw error }
                    try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                }
            }
        }
        // Nothing stays behind: the notes for these photos go with them.
        await TrashSync.shared.removeFinishedNotes()
    }

    private static func deleteBatch(_ batch: [MediaItem], expiredBy: Date?) async throws {
        let env = AppEnvironment.shared
        // Re-read under the gate: the user may have recovered these since the list was made.
        let claimed: [MediaItem] = batch.compactMap { item in
            TrashGate.shared.claim(item.id) {
                (try? env.store.item(id: item.id)).flatMap { current in
                    guard current.status == .trashed else { return nil }
                    if let expiredBy, !CloudTrash.isExpired(current, now: expiredBy) { return nil }
                    return current
                }
            }
        }
        defer { claimed.forEach { TrashGate.shared.release($0.id) } }
        guard !claimed.isEmpty else { return }
        if !DemoMode.isActive {
            guard let chatId = env.library.chatId else { throw LibraryError.noLibrary }
            try await env.td.deleteMessages(chatId: chatId, ids: claimed.flatMap(\.allMessageIds))
        }
        for item in claimed {
            try env.store.forgetDeletedItem(item)
            env.thumbnailCache.remove(CloudMediaService.thumbnailKey(item))
            appLog("Deleted \(item.filename) from cloud")
        }
        // A delete note that hadn't gone yet has nothing left to say.
        try env.store.clearTrashChanges(.delete, itemIds: claimed.map(\.id))
    }

    /// Items in Recently Deleted, most recently deleted first.
    static func trashedItems() -> [MediaItem] {
        ((try? AppEnvironment.shared.store.items(status: .trashed)) ?? [])
            .sorted { ($0.trashedAt ?? .distantPast) > ($1.trashedAt ?? .distantPast) }
    }

    /// Deletes items whose 30 days in Recently Deleted are over. Keeps everything unless Telegram's time is known, this
    /// device is up to date, and a note in the channel still says the item was deleted. Quietly retried next time on failure.
    static func emptyExpiredTrash() async {
        let env = AppEnvironment.shared
        if DemoMode.isActive {
            try? await deletePermanently(trashedItems().filter { CloudTrash.isExpired($0) }, expiredBy: Date())
            return
        }
        guard env.isConfigured, env.library.isUnlocked else { return }
        // Nothing due by this device's clock means nothing is due at all: the earlier clock decides.
        guard trashedItems().contains(where: { CloudTrash.isExpired($0) }) else { return }
        let telegram = await env.td.telegramTime(timeout: 30)
        logClockGap(telegram)
        guard let now = CloudTrash.expiryClock(device: Date(), telegram: telegram) else {
            appLog("Kept Recently Deleted as it is: Telegram's time isn't known yet")
            return
        }
        do {
            // A recover on another device must be seen before anything goes. Items no note keeps here anymore follow Telegram.
            try await env.library.catchUp()
            guard !env.library.needsRepairScan, let chatId = env.library.chatId else { return }
            try await TrashSync.shared.followTelegram()
            let newest = TrashLog.latest(try env.store.trashNotes())
            let waiting = Set(try env.store.queuedTrashChanges(chatId: chatId).values.flatMap { $0 })
            let due = trashedItems().filter { CloudTrash.isExpired($0, now: now) && (!TrashSync.sendsNotes || TrashLog.mayPurge($0, latest: newest[$0.id], waiting: waiting)) }
            try await deletePermanently(due, expiredBy: now)
        } catch {
            AppLog.shared.warn("Emptying Recently Deleted failed: \(error.localizedDescription)")
        }
    }
}

enum TrashError: LocalizedError {
    case alreadyDeleting
    case alreadyGone(Int)
    case needsConnection
    var errorDescription: String? {
        switch self {
        case .alreadyDeleting: return "Some items were already being removed from your Telegram library and couldn't be recovered."
        case .alreadyGone(let count): return count == 1 ? "This photo was already deleted from your Telegram library on another device, so it can't be recovered."
            : "\(count) photos were already deleted from your Telegram library on another device, so they can't be recovered."
        case .needsConnection: return "Couldn't reach Telegram. Check your connection and try again."
        }
    }
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

extension Notification.Name {
    /// An album was made or items were added to one: album lists read Photos again.
    static let albumsChanged = Notification.Name("LelvoAlbumsChanged")
}
