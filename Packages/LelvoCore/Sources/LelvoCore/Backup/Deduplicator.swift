import Foundation
import CryptoKit

/// Decides whether an asset needs uploading. Two keys protect against duplicates:
/// the PhotoKit `localIdentifier` (cheap, stable on one device) and the SHA-256 of the original bytes
/// (survives reinstalls, new devices and re-imported photos).
public struct Deduplicator {
    public enum Decision: Equatable {
        /// Known by local identifier — nothing to do (`item` may still be in progress).
        case known(MediaItem)
        /// Same bytes already backed up/in progress under another identifier — link, don't upload.
        case duplicateContent(MediaItem)
        /// Never seen: upload.
        case upload
    }

    let store: LibraryStore

    public init(store: LibraryStore) { self.store = store }

    /// Stage 1, before exporting any bytes.
    public func check(localIdentifier: String) throws -> MediaItem? {
        try store.item(localIdentifier: localIdentifier)
    }

    /// Stage 2, after hashing the exported original.
    public func decide(localIdentifier: String, sha256: String) throws -> Decision {
        if let byId = try store.item(localIdentifier: localIdentifier) { return .known(byId) }
        let matches = try store.items(sha256: sha256).filter { $0.status != .failed }
        if let best = matches.first(where: { $0.status == .backedUp }) ?? matches.first {
            return .duplicateContent(best)
        }
        return .upload
    }

    /// Records that `localIdentifier` is the same content as `existing` (no upload needed).
    /// Adopts the identifier when the existing item has none or its asset is gone (restore / new device);
    /// otherwise stores an alias for the duplicate asset. Returns true if the identifier was adopted.
    @discardableResult
    public func link(localIdentifier: String, to existing: MediaItem, existingAssetIsMissing: Bool) throws -> Bool {
        if existing.localIdentifier == nil || existingAssetIsMissing {
            try store.update(id: existing.id) { $0.localIdentifier = localIdentifier }
            return true
        }
        try store.addAlias(localIdentifier: localIdentifier, itemId: existing.id)
        return false
    }

    /// Whether a photo with the same original bytes as `twin` is really the same photo. Its edit counts too: a cropped
    /// copy of an already backed-up photo was taken for a duplicate, its crop was never uploaded, and deleting it lost
    /// the crop. `editHash` is the SHA-256 of the photo's rendered edit, nil when it isn't edited.
    public static func isSamePhoto(editHash: String?, as twin: MediaItem) -> Bool {
        guard let editHash else { return true }
        return twin.roleHashes?["e"] == editHash
    }

    /// The hashes saved on a queued item when it was last tried still describe its files, so a retry (network error,
    /// Telegram's pause, the app killed) can skip hashing a big video again. True only when the photo hasn't changed
    /// since (same modification date, which Photos moves on every edit) and each exported file still has the size it
    /// had; anything else hashes again, so the caption always carries the hash of the bytes uploaded.
    public static func canReuseHashes(of item: MediaItem, modified: Date?, sizes: (primary: Int64, paired: Int64?, edited: Int64?)) -> Bool {
        guard !item.sha256.isEmpty, let hashedAt = item.assetModifiedAt, hashedAt == modified else { return false }
        guard sizes.primary == item.fileSize, sizes.paired == item.pairedVideoSize, sizes.edited == item.editedSize else { return false }
        if sizes.paired != nil, item.roleHashes?["pv"] == nil { return false }
        if sizes.edited != nil, item.roleHashes?["e"] == nil { return false }
        return true
    }

    /// Streaming SHA-256 of a file.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Hash for a Live Photo: combines both resources so a re-edited pair is a new item.
    public static func combinedHash(_ hashes: [String]) -> String {
        hashes.count == 1 ? hashes[0] : IndexCodec.sha256Hex(Data(hashes.joined(separator: "+").utf8))
    }
}
