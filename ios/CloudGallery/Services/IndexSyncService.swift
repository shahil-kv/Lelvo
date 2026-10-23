import Foundation
import UIKit
import CloudGalleryCore

enum IndexSyncError: LocalizedError {
    case notConfigured
    case noPinnedIndex
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Connect your bot and set a passphrase first."
        case .noPinnedIndex: return "No CloudGallery index is pinned in this chat yet."
        case .checksumMismatch: return "The index chunks don't match their manifest. Try again."
        }
    }
}

/// Uploads the encrypted index after each batch (pinned, replacing the previous one) and restores it on a fresh install.
actor IndexSyncService {
    private unowned let env: AppEnvironment

    init(environment: AppEnvironment) { self.env = environment }

    private static let messageIdsKey = "indexMessageIds"
    private static let uploadedAtKey = "indexUploadedAt"

    nonisolated var lastUploadedAt: Date? {
        env.store.meta(Self.uploadedAtKey).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
    }

    private var previousMessageIds: [Int64] {
        (env.store.meta(Self.messageIdsKey) ?? "").split(separator: ",").compactMap { Int64($0) }
    }

    func buildIndex() throws -> CloudIndex {
        let items = try env.store.items(status: .backedUp)
        return CloudIndex(deviceName: "iPhone", fileKeySalt: env.ensureFileKeySalt(), items: items)
    }

    /// Encrypts the current index with the passphrase for export to Files.
    func exportSealed() throws -> URL {
        guard let passphrase = env.passphrase else { throw IndexSyncError.notConfigured }
        let sealed = try IndexCodec.seal(.index(try buildIndex()), passphrase: passphrase)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CloudGallery-index-\(f.string(from: Date())).cgx")
        try sealed.write(to: url, options: .atomic)
        return url
    }

    /// Uploads and pins a fresh index, then unpins/deletes the previous one.
    func upload() async throws {
        guard let client = env.client(), let chatId = env.chatId, let passphrase = env.passphrase else { throw IndexSyncError.notConfigured }
        let bgTask = await MainActor.run { UIApplication.shared.beginBackgroundTask(withName: "IndexUpload") }
        defer { Task { @MainActor in UIApplication.shared.endBackgroundTask(bgTask) } }

        let index = try buildIndex()
        let sealed = try IndexCodec.seal(.index(index), passphrase: passphrase)
        var newIds: [Int64] = []
        let pinned: TGMessage
        if sealed.count <= IndexCodec.maxChunkSize {
            pinned = try await client.sendDocument(chatId: chatId, data: sealed, fileName: IndexCodec.pinnedFileName,
                                                   caption: IndexCodec.caption)
        } else {
            var chunks: [RemoteFile] = []
            for (i, part) in IndexCodec.split(sealed).enumerated() {
                let msg = try await client.sendDocument(chatId: chatId, data: part, fileName: "cloudgallery-index.part\(i).bin",
                                                        caption: "#cloudgallery-index-part \(i)")
                chunks.append(try RemoteFile(message: msg))
                newIds.append(msg.messageId)
            }
            let manifest = IndexManifest(totalSize: Int64(sealed.count), sha256: IndexCodec.sha256Hex(sealed), chunks: chunks)
            pinned = try await client.sendDocument(chatId: chatId, data: try IndexCodec.seal(.manifest(manifest), passphrase: passphrase),
                                                   fileName: IndexCodec.pinnedFileName, caption: IndexCodec.caption)
        }
        newIds.append(pinned.messageId)
        try await client.pinChatMessage(chatId: chatId, messageId: pinned.messageId)

        let old = previousMessageIds
        env.store.setMeta(Self.messageIdsKey, newIds.map(String.init).joined(separator: ","))
        env.store.setMeta(Self.uploadedAtKey, String(Date().timeIntervalSince1970))
        env.store.setMeta("indexDirty", nil)
        appLog("Index uploaded: \(index.items.count) items, \(sealed.count) bytes, \(newIds.count) message(s)")

        // Clean up the replaced index; failures here are harmless.
        if let last = old.last { try? await client.unpinChatMessage(chatId: chatId, messageId: last) }
        for id in old where !newIds.contains(id) { try? await client.deleteMessage(chatId: chatId, messageId: id) }
    }

    /// Looks for a pinned CloudGallery index (used during onboarding to offer restore).
    func pinnedIndexMessage(client: TelegramClient, chatId: String) async throws -> TGMessage? {
        let chat = try await client.getChat(chatId)
        guard let msg = chat.pinnedMessage?.value, msg.document?.fileName == IndexCodec.pinnedFileName else { return nil }
        return msg
    }

    /// Downloads, decrypts and merges the pinned index. Returns the number of restored items.
    @discardableResult
    func restore(passphrase: String) async throws -> Int {
        guard let client = env.client(), let chatId = env.chatId else { throw IndexSyncError.notConfigured }
        guard let msg = try await pinnedIndexMessage(client: client, chatId: chatId), let doc = msg.document else {
            throw IndexSyncError.noPinnedIndex
        }
        let sealed = try await client.downloadData(fileId: doc.fileId)
        var ids: [Int64] = [msg.messageId]
        let index: CloudIndex
        switch try IndexCodec.open(sealed, passphrase: passphrase) {
        case .index(let i):
            index = i
        case .manifest(let manifest):
            var blob = Data()
            for chunk in manifest.chunks {
                blob.append(try await client.downloadData(fileId: chunk.fileId))
                ids.insert(chunk.messageId, at: ids.count - 1)
            }
            guard IndexCodec.sha256Hex(blob) == manifest.sha256 else { throw IndexSyncError.checksumMismatch }
            guard case .index(let i) = try IndexCodec.open(blob, passphrase: passphrase) else { throw CryptoError.badFormat }
            index = i
        }
        let count = try merge(index)
        env.store.setMeta(Self.messageIdsKey, ids.map(String.init).joined(separator: ","))
        appLog("Restored \(count) items from the cloud index")
        return count
    }

    /// Restores from an index file exported to Files.
    @discardableResult
    func restore(fromFile url: URL, passphrase: String) throws -> Int {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard case .index(let index) = try IndexCodec.open(try Data(contentsOf: url), passphrase: passphrase) else {
            throw CryptoError.badFormat
        }
        return try merge(index)
    }

    private func merge(_ index: CloudIndex) throws -> Int {
        if let salt = index.fileKeySalt, KeychainStore.data(for: .fileKeySalt) != salt {
            KeychainStore.set(salt, for: .fileKeySalt)
            KeychainStore.set(nil as Data?, for: .fileMasterKey)
        }
        // Keep identifiers only for assets that still exist on this device; others become cloud-only.
        let existing = env.photos.existingIdentifiers(index.items.compactMap(\.localIdentifier))
        var merged: [LibraryItem] = []
        for var item in index.items {
            if let local = try env.store.item(id: item.id), local.status == .backedUp {
                item.localIdentifier = local.localIdentifier ?? item.localIdentifier
            }
            if let id = item.localIdentifier, !existing.contains(id) { item.localIdentifier = nil }
            item.status = .backedUp
            merged.append(item)
        }
        try env.store.upsert(merged)
        return merged.count
    }
}
