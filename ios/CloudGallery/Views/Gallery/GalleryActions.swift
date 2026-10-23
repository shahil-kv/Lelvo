import Foundation
import Photos
import CloudGalleryCore

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
            let named = dir.appendingPathComponent(exported.primaryFilename.sanitizedFilename)
            try FileManager.default.moveItem(at: exported.primaryURL, to: named)
            return named
        }
        guard let item = entry.item else { throw PhotoLibraryError.assetMissing }
        let cached = try await env.media.original(for: item)
        return try env.media.shareableCopy(of: cached, filename: item.filename)
    }

    /// Downloads a cloud item (≤ 20 MB) into Photos and links it so it is not uploaded again.
    static func saveToPhotos(_ item: MediaItem) async throws {
        let env = AppEnvironment.shared
        let status = PhotoLibraryService.authorizationStatus
        guard status == .authorized || status == .limited else { throw PhotoLibraryError.notAuthorized }
        let primary = try env.media.shareableCopy(of: try await env.media.original(for: item), filename: item.filename)
        var paired: URL?
        if item.kind == .livePhoto, item.pairedVideo != nil {
            paired = try env.media.shareableCopy(of: try await env.media.original(for: item, role: .pairedVideo),
                                                 filename: item.pairedVideoFilename ?? "video.mov")
        }
        defer {
            try? FileManager.default.removeItem(at: primary.deletingLastPathComponent())
            if let paired { try? FileManager.default.removeItem(at: paired.deletingLastPathComponent()) }
        }
        if let newId = try await env.photos.saveToPhotos(item: item, primary: primary, pairedVideo: paired) {
            try env.store.update(id: item.id) { $0.localIdentifier = newId }
            env.engine.markIndexDirty()
        }
    }

    /// Deletes the item's messages from the channel, drops it from the index and re-uploads the index.
    static func deleteFromCloud(_ items: [MediaItem]) async throws {
        let env = AppEnvironment.shared
        guard let client = env.client(), let chatId = env.chatId else { throw IndexSyncError.notConfigured }
        for item in items {
            for remote in [item.original, item.pairedVideo, item.thumbnail].compactMap({ $0 }) {
                do {
                    try await client.deleteMessage(chatId: chatId, messageId: remote.messageId)
                } catch TelegramError.api(_, let d) where d.lowercased().contains("not found") {
                    // Already gone.
                }
            }
            try env.store.delete(id: item.id)
            appLog("Deleted \(item.id) from cloud")
        }
        env.engine.markIndexDirty()
        try await env.indexSync.upload()
    }
}
