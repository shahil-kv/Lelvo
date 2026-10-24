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

    /// Deletes every message of the items (all resources and parts) from the channel.
    static func deleteFromCloud(_ items: [MediaItem]) async throws {
        let env = AppEnvironment.shared
        guard let chatId = env.library.chatId else { throw LibraryError.noLibrary }
        try await env.td.waitUntilReady(timeout: 20)
        for item in items {
            try await env.td.deleteMessages(chatId: chatId, ids: item.allMessageIds)
            try env.store.delete(id: item.id)
            env.thumbnailCache.remove(CloudMediaService.thumbnailKey(item))
            appLog("Deleted \(item.filename) from cloud")
        }
    }
}
