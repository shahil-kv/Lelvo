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

    /// Confirms every part of every required resource is still in the channel with the recorded size.
    func verify(_ item: MediaItem) async -> Bool {
        guard item.status == .backedUp, item.sizeClass == .normal, let chatId = env.library.chatId else { return false }
        var parts: [RemoteFile] = []
        if item.cloudParts != nil {
            for role in item.requiredCaptionRoles where role != "t" {
                let p = item.parts(role)
                guard !p.isEmpty, p.count == (item.expectedParts?[role] ?? 1) else { return false }
                parts += p
            }
        } else {
            parts = [item.original, item.pairedVideo].compactMap { $0 }
            if item.kind == .livePhoto && item.pairedVideo == nil { return false }
        }
        guard !parts.isEmpty else { return false }
        do {
            try await env.td.waitUntilReady(timeout: 20)
            for part in parts {
                guard let (file, _) = try await env.td.documentFile(chatId: chatId, messageId: part.messageId) else {
                    AppLog.shared.warn("Verification: message \(part.messageId) of \(item.filename) is gone")
                    return false
                }
                guard file.size == part.size, file.remote.isUploadingCompleted || !file.remote.id.isEmpty else {
                    AppLog.shared.warn("Verification: size mismatch for \(item.filename)")
                    return false
                }
            }
            try env.store.update(id: item.id) { $0.verifiedAt = Date() }
            return true
        } catch {
            AppLog.shared.warn("Verification of \(item.filename) failed: \(error.localizedDescription)")
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
