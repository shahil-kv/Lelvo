import Foundation
import Photos
import CloudGalleryCore

/// Finds items that are provably safe to delete from the phone and deletes them via PhotoKit
/// (iOS always shows its own confirmation). Nothing unverified or larger than 20 MB is ever offered.
final class FreeUpSpaceService: @unchecked Sendable {
    private unowned let env: AppEnvironment
    /// A verification older than this is redone before deletion.
    static let verificationLifetime: TimeInterval = 24 * 60 * 60

    init(environment: AppEnvironment) { self.env = environment }

    /// Backed-up items still on the phone whose originals the Bot API can re-download.
    func candidates() -> [MediaItem] {
        let items = ((try? env.store.items(status: .backedUp)) ?? []).filter { $0.sizeClass == .normal && $0.localIdentifier != nil }
        let present = env.photos.existingIdentifiers(items.compactMap(\.localIdentifier))
        return items.filter { present.contains($0.localIdentifier!) }
    }

    func isFreshlyVerified(_ item: MediaItem) -> Bool {
        guard let at = item.verifiedAt else { return false }
        return Date().timeIntervalSince(at) < Self.verificationLifetime
    }

    /// Checks every required message still exists and every file_id still resolves to the recorded size.
    func verify(_ item: MediaItem) async -> Bool {
        guard let client = env.client(), let chatId = env.chatId, item.status == .backedUp, item.sizeClass == .normal else { return false }
        do {
            for role in item.requiredRoles {
                guard let remote = item.remote(for: role) else { return false }
                if role == .thumbnail { continue }
                guard try await client.messageExists(chatId: chatId, messageId: remote.messageId, caption: item.caption(for: role)) else {
                    AppLog.shared.warn("Verification: message for \(item.id) \(role.rawValue) is gone")
                    return false
                }
                let file = try await client.getFile(remote.fileId)
                guard let size = file.fileSize, size == remote.size, file.filePath != nil else {
                    AppLog.shared.warn("Verification: size mismatch for \(item.id) \(role.rawValue)")
                    return false
                }
            }
            try env.store.update(id: item.id) { $0.verifiedAt = Date() }
            return true
        } catch {
            AppLog.shared.warn("Verification of \(item.id) failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Deletes verified items from the photo library. Their records stay, so they remain in the gallery as cloud items.
    func delete(_ items: [MediaItem]) async throws -> Int {
        let safe = items.filter { isFreshlyVerified($0) && $0.sizeClass == .normal && $0.status == .backedUp }
        let ids = safe.compactMap(\.localIdentifier)
        guard !ids.isEmpty else { return 0 }
        try await env.photos.deleteAssets(ids)
        let stillThere = env.photos.existingIdentifiers(ids)
        let deleted = ids.filter { !stillThere.contains($0) }
        appLog("Freed up space: deleted \(deleted.count) items from the photo library")
        return deleted.count
    }

    static func bytes(of items: [MediaItem]) -> Int64 {
        items.reduce(0) { $0 + $1.fileSize + ($1.pairedVideoSize ?? 0) }
    }
}
