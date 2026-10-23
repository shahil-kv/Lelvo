import Foundation
import CryptoKit
import TDLibKit
import CloudGalleryCore

/// Random-access reads of cloud resources: maps plaintext ranges → CGFE chunks → split parts → TDLib
/// ranged downloads (docs/ARCHITECTURE.md "Streaming").
final class MediaReader: @unchecked Sendable {
    private let td: TDService
    private let library: LibraryService
    private let lock = NSLock()
    /// message id → TDLib file id (session-local).
    private var fileIds: [Int64: Int] = [:]
    /// item+role → CGFE header bytes.
    private var headers: [String: Data] = [:]

    init(td: TDService, library: LibraryService) {
        self.td = td
        self.library = library
    }

    enum ReadError: LocalizedError {
        case missing
        case locked
        var errorDescription: String? {
            switch self {
            case .missing: return "This file is no longer in your Telegram channel."
            case .locked: return "Unlock the library with your passphrase to view encrypted items."
            }
        }
    }

    // MARK: - Parts

    private func parts(_ item: MediaItem, role: String) -> [CloudGalleryCore.RemoteFile] {
        if item.cloudParts != nil { return item.parts(role) }
        // Legacy 1.0 bot uploads: one message per role.
        switch role {
        case "o": return item.original.map { [$0] } ?? []
        case "pv": return item.pairedVideo.map { [$0] } ?? []
        case "t": return item.thumbnail.map { [$0] } ?? []
        default: return []
        }
    }

    private func tdFileId(for part: CloudGalleryCore.RemoteFile) async throws -> Int {
        if let cached = lock.withLock({ fileIds[part.messageId] }) { return cached }
        guard let chatId = library.chatId, let (file, _) = try await td.documentFile(chatId: chatId, messageId: part.messageId) else {
            throw ReadError.missing
        }
        lock.withLock { fileIds[part.messageId] = file.id }
        return file.id
    }

    /// Size of the stored stream (ciphertext for E2E), summed over parts.
    func streamSize(_ item: MediaItem, role: String) -> Int64 {
        parts(item, role: role).reduce(0) { $0 + $1.size }
    }

    /// Raw stream bytes for `range`, spanning split parts.
    func readStream(_ item: MediaItem, role: String, range: Range<Int64>, priority: Int = 32) async throws -> Data {
        let ps = parts(item, role: role)
        guard !ps.isEmpty else { throw ReadError.missing }
        let partSize = ps.count > 1 ? ps[0].size : max(ps[0].size, 1)
        let layout = PartLayout(partSize: partSize, totalSize: ps.reduce(0) { $0 + $1.size })
        var out = Data()
        for seg in layout.segments(for: range) {
            let fileId = try await tdFileId(for: ps[seg.part])
            out.append(try await td.read(fileId: fileId, offset: seg.offset, count: seg.length, priority: priority))
        }
        return out
    }

    // MARK: - Plaintext

    private func isEncrypted(_ item: MediaItem) -> Bool { item.encrypted && item.cloudParts != nil }

    private func cgfeHeader(_ item: MediaItem, role: String) async throws -> Data {
        let key = "\(item.id)/\(role)"
        if let h = lock.withLock({ headers[key] }) { return h }
        let h = try await readStream(item, role: role, range: 0..<Int64(CGFELayout.headerLength))
        lock.withLock { headers[key] = h }
        return h
    }

    private func reader(_ item: MediaItem, role: String) async throws -> CGFERandomReader {
        guard let master = library.keys?.master else { throw ReadError.locked }
        return try CGFERandomReader(header: try await cgfeHeader(item, role: role), cipherSize: streamSize(item, role: role), master: master)
    }

    /// Plaintext size of a resource.
    func plaintextSize(_ item: MediaItem, role: String) async throws -> Int64 {
        guard isEncrypted(item) else { return streamSize(item, role: role) }
        return try await reader(item, role: role).layout.plaintextSize
    }

    /// Plaintext bytes for `range` (decrypting only the chunks needed).
    func read(_ item: MediaItem, role: String, range: Range<Int64>, priority: Int = 32) async throws -> Data {
        guard isEncrypted(item) else { return try await readStream(item, role: role, range: range, priority: priority) }
        let r = try await reader(item, role: role)
        let clamped = max(0, range.lowerBound) ..< min(r.layout.plaintextSize, range.upperBound)
        guard !clamped.isEmpty else { return Data() }
        let chunks = r.layout.chunks(coveringPlaintext: clamped)
        let cipherRange = r.layout.cipherRange(ofChunk: chunks.lowerBound).lowerBound ..< r.layout.cipherRange(ofChunk: chunks.upperBound).upperBound
        let cipher = try await readStream(item, role: role, range: cipherRange, priority: priority)
        var out = Data()
        for i in chunks {
            let cr = r.layout.cipherRange(ofChunk: i)
            let local = Int(cr.lowerBound - cipherRange.lowerBound) ..< Int(cr.upperBound - cipherRange.lowerBound)
            let plain = try r.decryptChunk(i, sealed: cipher.subdata(in: local))
            let chunkStart = i * Int64(r.layout.chunkSize)
            let from = max(clamped.lowerBound, chunkStart) - chunkStart
            let to = min(clamped.upperBound, chunkStart + Int64(plain.count)) - chunkStart
            if to > from { out.append(plain.subdata(in: Int(from)..<Int(to))) }
        }
        return out
    }

    /// Writes the whole plaintext resource to `destination` in 8 MiB steps (photos, share, save to library).
    func download(_ item: MediaItem, role: String, to destination: URL, progress: ((Double) -> Void)? = nil) async throws {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Fast path: a single unencrypted part — let TDLib fetch it in one go and copy it out.
        let ps = parts(item, role: role)
        if !isEncrypted(item), ps.count == 1 {
            let path = try await td.download(fileId: try await tdFileId(for: ps[0]))
            try fm.copyItem(at: path, to: destination)
            progress?(1)
            return
        }
        let total = try await plaintextSize(item, role: role)
        fm.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        let step: Int64 = 8 << 20
        var offset: Int64 = 0
        while offset < total {
            try Task.checkCancellation()
            let data = try await read(item, role: role, range: offset ..< min(total, offset + step), priority: 16)
            try out.write(contentsOf: data)
            offset += Int64(data.count)
            progress?(Double(offset) / Double(max(total, 1)))
            if data.isEmpty { break }
        }
    }

    // MARK: - Thumbnails

    /// JPEG thumbnail bytes: the document thumbnail (plain), the encrypted `t` resource (E2E),
    /// or the legacy bot thumbnail message.
    func thumbnailData(_ item: MediaItem) async throws -> Data {
        if isEncrypted(item) || item.cloudParts == nil {
            if isEncrypted(item) {
                let size = try await plaintextSize(item, role: "t")
                return try await read(item, role: "t", range: 0..<size, priority: 8)
            }
            return try await readStream(item, role: "t", range: 0..<streamSize(item, role: "t"), priority: 8)
        }
        guard let chatId = library.chatId, let first = item.parts("o").first,
              let (_, doc) = try await td.documentFile(chatId: chatId, messageId: first.messageId),
              let thumb = doc.thumbnail else { throw ReadError.missing }
        let path = try await td.download(fileId: thumb.file.id, priority: 8)
        return try Data(contentsOf: path)
    }

    /// Prefetches the start of a video so playback begins instantly when swiped to.
    func prefetch(_ item: MediaItem, role: String = "o", bytes: Int64 = 2 << 20) {
        Task.detached(priority: .utility) { [self] in
            let size = (try? await plaintextSize(item, role: role)) ?? 0
            _ = try? await read(item, role: role, range: 0..<min(size, bytes), priority: 4)
        }
    }

    func forgetCaches() {
        lock.withLock {
            fileIds.removeAll()
            headers.removeAll()
        }
    }
}
