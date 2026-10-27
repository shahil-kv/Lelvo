import Foundation
import CryptoKit
import TDLibKit
import MemvoCore

/// One resource of an item, exported to disk and ready to upload.
struct PreparedResource {
    /// Caption role: "o", "pv" or "t".
    let role: String
    let fileURL: URL
    /// Caption metadata without `p`/`e`; the uploader fills those in.
    let meta: CaptionMeta
}

/// Uploads resources in format 1: optional CGFE encryption, splitting above the account limit,
/// one confirmed document message per part, and a size check before anything counts as uploaded.
final class CloudUploader: @unchecked Sendable {
    private let td: TDService
    private let library: LibraryService
    private let staging: URL

    init(td: TDService, library: LibraryService, staging: URL) {
        self.td = td
        self.library = library
        self.staging = staging
    }

    /// Uploads `resource`, skipping parts already confirmed in `existing` (resume after interruption).
    /// `checkpoint` is called after every confirmed part so progress survives a crash.
    func upload(itemId: String, resource: PreparedResource, encrypted: Bool, thumbnail: (URL, Int, Int)?,
                existing: [MemvoCore.RemoteFile],
                checkpoint: @escaping ([MemvoCore.RemoteFile], Int) throws -> Void,
                progress: @escaping (Int64, Int64) -> Void) async throws -> [MemvoCore.RemoteFile] {
        guard let chatId = library.chatId else { throw LibraryError.noLibrary }
        let workDir = staging.appendingPathComponent("up-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        // 1. The stream to store: the original, or its CGFE ciphertext.
        var stream = resource.fileURL
        var captionKey: SymmetricKeyBox?
        if encrypted {
            guard let keys = library.keys else { throw LibraryError.locked }
            let out = workDir.appendingPathComponent("stream.cge")
            let chunk = resource.role == "sp" ? FileCrypto.fastVersionChunkSize : FileCrypto.defaultChunkSize
            try FileCrypto.encrypt(input: resource.fileURL, output: out, masterKey: keys.master, chunkSize: chunk)
            stream = out
            captionKey = SymmetricKeyBox(keys.captionKey)
        }
        let streamSize = try Self.size(of: stream)
        let limit = await td.uploadLimit()
        let layout = PartLayout.forUpload(size: streamSize, limit: limit)

        // 2. Parts.
        var done = existing.count == layout.partCount ? [] : Array(existing.prefix(layout.partCount))
        if done.count == layout.partCount { return done }
        for index in done.count..<layout.partCount {
            try Task.checkCancellation()
            let partName = Self.telegramName(itemId: itemId, role: resource.role, original: resource.meta.n,
                                             encrypted: encrypted, part: layout.isSplit ? index : nil)
            let partURL = workDir.appendingPathComponent(partName)
            let partSize = layout.size(ofPart: index)
            if layout.isSplit {
                try Self.copyRange(from: stream, offset: Int64(index) * layout.partSize, length: partSize, to: partURL)
            } else {
                try Self.linkOrCopy(stream, to: partURL)
            }

            var meta = resource.meta
            meta.p = layout.isSplit ? [Int64(index), Int64(layout.partCount), layout.partSize] : nil
            meta.e = encrypted ? 1 : nil
            meta.src = "ios"
            let caption = try CaptionCodec.encode(meta, captionKey: captionKey?.key)

            let base = Int64(index) * layout.partSize
            let message = try await td.sendDocument(chatId: chatId, fileURL: partURL, caption: caption,
                                                    thumbnail: index == 0 && !encrypted ? thumbnail : nil) { sent, _ in
                progress(base + sent, streamSize)
            }
            guard case .messageDocument(let doc) = message.content else {
                try? await td.deleteMessages(chatId: chatId, ids: [message.id])
                throw TDServiceError.unexpectedContent
            }
            let file = doc.document.document
            guard file.size == partSize else {
                try? await td.deleteMessages(chatId: chatId, ids: [message.id])
                throw TDServiceError.sizeMismatch(expected: partSize, actual: file.size)
            }
            done.append(MemvoCore.RemoteFile(messageId: message.id, fileId: file.remote.id,
                                                    fileUniqueId: file.remote.uniqueId, size: file.size))
            try checkpoint(done, layout.partCount)
            // TDLib keeps the upload's temporary file as this file's local copy; it's deleted below, so the first
            // read when playing from the cloud would fail and retry. Forget it now: reads then go to Telegram directly.
            await td.deleteLocalCopy(fileId: file.id)
            try? FileManager.default.removeItem(at: partURL)
            progress(Int64(index + 1) * layout.partSize, streamSize)
        }
        return done
    }

    /// File name stored on Telegram (docs/CLOUD_FORMAT.md §3).
    static func telegramName(itemId: String, role: String, original: String, encrypted: Bool, part: Int?) -> String {
        if encrypted {
            if let part { return "\(itemId).\(role).p\(String(format: "%03d", part + 1)).cge" }
            return "\(itemId).\(role).cge"
        }
        let safe = original.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "_")
        guard let part else { return safe.isEmpty ? "\(itemId)" : safe }
        return "\(safe).part\(String(format: "%03d", part + 1))"
    }

    static func size(of url: URL) throws -> Int64 {
        ((try FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    static func linkOrCopy(_ src: URL, to dst: URL) throws {
        try? FileManager.default.removeItem(at: dst)
        do { try FileManager.default.linkItem(at: src, to: dst) } catch { try FileManager.default.copyItem(at: src, to: dst) }
    }

    static func copyRange(from src: URL, offset: Int64, length: Int64, to dst: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: dst)
        fm.createFile(atPath: dst.path, contents: nil)
        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: dst)
        defer { try? output.close() }
        try input.seek(toOffset: UInt64(offset))
        var remaining = length
        while remaining > 0 {
            let n = Int(min(remaining, 4 << 20))
            guard let chunk = try input.read(upToCount: n), !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk)
            remaining -= Int64(chunk.count)
        }
    }
}

/// Sendable wrapper for a CryptoKit key captured across await points.
struct SymmetricKeyBox: @unchecked Sendable {
    let key: SymmetricKey
    init(_ key: SymmetricKey) { self.key = key }
}

