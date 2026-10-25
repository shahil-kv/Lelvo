import Foundation
import Photos
import MemvoCore

/// Batch and single-item actions shared by the grid and the viewer.
enum GalleryActions {
    /// A file with the item's real name, ready for the share sheet.
    static func shareableFile(for entry: GalleryEntry) async throws -> URL {
        let env = AppEnvironment.shared
        if let asset = entry.asset {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Share-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let exported = try await env.photos.exportOriginal(of: asset, into: dir)
            if let paired = exported.pairedVideoURL { try? FileManager.default.removeItem(at: paired) }
            // Share what the user sees: the edit when there is one, like Photos.
            let source = exported.editedURL ?? exported.primaryURL
            let named = dir.appendingPathComponent((exported.editedURL != nil ? exported.editedFilename : nil)?.sanitizedFilename
                                                   ?? exported.primaryFilename.sanitizedFilename)
            try FileManager.default.moveItem(at: source, to: named)
            return named
        }
        guard let item = entry.item else { throw PhotoLibraryError.assetMissing }
        let cached = try await env.media.displayed(for: item)
        return try env.media.shareableCopy(of: cached, filename: CloudMediaService.displayedFilename(item))
    }

    /// Downloads a cloud item into Photos and links it so it is not uploaded again.
    static func saveToPhotos(_ item: MediaItem) async throws {
        let env = AppEnvironment.shared
        let status = PhotoLibraryService.authorizationStatus
        guard status == .authorized || status == .limited else { throw PhotoLibraryError.notAuthorized }
        // Saves what the user sees (the edit, if any); the untouched original stays in the cloud.
        let primary = try env.media.shareableCopy(of: try await env.media.displayed(for: item), filename: CloudMediaService.displayedFilename(item))
        var paired: URL?
        if item.kind == .livePhoto, !item.parts("pv").isEmpty || item.pairedVideo != nil {
            paired = try env.media.shareableCopy(of: try await env.media.original(for: item, role: .pairedVideo),
                                                 filename: item.pairedVideoFilename ?? "video.mov")
        }
        defer {
            try? FileManager.default.removeItem(at: primary.deletingLastPathComponent())
            if let paired { try? FileManager.default.removeItem(at: paired.deletingLastPathComponent()) }
        }
        if let newId = try await env.photos.saveToPhotos(item: item, primary: primary, pairedVideo: paired) {
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

    static func recover(_ items: [MediaItem]) throws {
        let env = AppEnvironment.shared
        for item in items { try env.store.update(id: item.id) { CloudTrash.recover(&$0) } }
        appLog("Recovered \(items.count) items from Recently Deleted")
    }

    /// Deletes every message of the trashed items (all resources and parts) from the channel. Only items in
    /// Recently Deleted can go; anything else is left alone.
    static func deletePermanently(_ items: [MediaItem]) async throws {
        let env = AppEnvironment.shared
        let trashed = items.compactMap { try? env.store.item(id: $0.id) }.filter { $0.status == .trashed }
        guard !trashed.isEmpty else { return }
        if DemoMode.isActive {
            for item in trashed { try env.store.delete(id: item.id) }
            return
        }
        guard let chatId = env.library.chatId else { throw LibraryError.noLibrary }
        try await env.td.waitUntilReady(timeout: 20)
        for item in trashed {
            try await env.td.deleteMessages(chatId: chatId, ids: item.allMessageIds)
            try env.store.delete(id: item.id)
            env.thumbnailCache.remove(CloudMediaService.thumbnailKey(item))
            appLog("Deleted \(item.filename) from cloud")
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
        do { try await deletePermanently(expired) }
        catch { AppLog.shared.warn("Emptying Recently Deleted failed: \(error.localizedDescription)") }
    }
}
