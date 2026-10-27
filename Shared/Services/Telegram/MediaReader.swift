import Foundation
import CryptoKit
import TDLibKit
import MemvoCore

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
    /// item+role → open players (`StreamingAsset`s) reading it.
    private var openStreams: [String: Int] = [:]

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

    private func parts(_ item: MediaItem, role: String) -> [MemvoCore.RemoteFile] {
        if item.cloudParts != nil { return item.parts(role) }
        // Legacy 1.0 bot uploads: one message per role.
        switch role {
        case "o": return item.original.map { [$0] } ?? []
        case "pv": return item.pairedVideo.map { [$0] } ?? []
        case "t": return item.thumbnail.map { [$0] } ?? []
        default: return []
        }
    }

    private func tdFileId(for part: MemvoCore.RemoteFile) async throws -> Int {
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
    /// `streaming` uses the player's continuous download window instead of one request per range.
    func readStream(_ item: MediaItem, role: String, range: Range<Int64>, priority: Int = 32, streaming: Bool = false) async throws -> Data {
        let ps = parts(item, role: role)
        guard !ps.isEmpty else { throw ReadError.missing }
        let partSize = ps.count > 1 ? ps[0].size : max(ps[0].size, 1)
        let layout = PartLayout(partSize: partSize, totalSize: ps.reduce(0) { $0 + $1.size })
        var out = Data()
        for seg in layout.segments(for: range) {
            let fileId = try await tdFileId(for: ps[seg.part])
            out.append(streaming
                       // A fast version arrives about four times faster than it plays: wait for nearby data.
                       ? try await td.streamRead(fileId: fileId, offset: seg.offset, count: seg.length,
                                                 ahead: role == "sp" ? 4 << 20 : 2 << 20, smallReads: role != "sp")
                       : try await td.read(fileId: fileId, offset: seg.offset, count: seg.length, priority: priority))
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
    func read(_ item: MediaItem, role: String, range: Range<Int64>, priority: Int = 32, streaming: Bool = false) async throws -> Data {
        guard isEncrypted(item) else { return try await readStream(item, role: role, range: range, priority: priority, streaming: streaming) }
        let r = try await reader(item, role: role)
        let clamped = max(0, range.lowerBound) ..< min(r.layout.plaintextSize, range.upperBound)
        guard !clamped.isEmpty else { return Data() }
        let chunks = r.layout.chunks(coveringPlaintext: clamped)
        let cipherRange = r.layout.cipherRange(ofChunk: chunks.lowerBound).lowerBound ..< r.layout.cipherRange(ofChunk: chunks.upperBound).upperBound
        let cipher = try await readStream(item, role: role, range: cipherRange, priority: priority, streaming: streaming)
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
    /// `evict`: drop TDLib's cached copy afterwards (bulk export shouldn't fill the phone).
    func download(_ item: MediaItem, role: String, to destination: URL, evict: Bool = false, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        defer {
            if evict {
                let ps = parts(item, role: role)
                Task { for p in ps { if let id = try? await tdFileId(for: p) { await td.deleteLocalCopy(fileId: id) } } }
            }
        }
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Fast path: a single unencrypted part — let TDLib fetch it in one go and copy it out.
        let ps = parts(item, role: role)
        if !isEncrypted(item), ps.count == 1 {
            // Someone is waiting (saving, sharing): top priority and live progress.
            let report: (@Sendable (Int64, Int64) -> Void)? = progress.map { p in { @Sendable done, total in p(Double(done) / Double(max(total, 1))) } }
            let path = try await td.download(fileId: try await tdFileId(for: ps[0]), priority: report != nil ? 32 : 16, progress: report)
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
                // One download by the file's stored id, decrypted here. Going through `read` looked up the message,
                // then fetched the 25-byte header and then the rest: three trips to Telegram per tile, which left
                // a zoomed-out grid empty for a long time.
                if let data = try? await wholeEncryptedThumbnail(item) { return data }
                let size = try await plaintextSize(item, role: "t")
                return try await read(item, role: "t", range: 0..<size, priority: 8)
            }
            return try await readStream(item, role: "t", range: 0..<streamSize(item, role: "t"), priority: 8)
        }
        guard let chatId = library.chatId, let first = item.parts("o").first else { throw ReadError.missing }
        // Fast path: the thumbnail's remote id from the last scan, downloaded directly.
        if let remoteId = library.thumbnails.remoteId(messageId: first.messageId, chatId: chatId),
           let path = try? await td.download(remoteId: remoteId, priority: 8) {
            return try Data(contentsOf: path)
        }
        guard let (_, doc) = try await td.documentFile(chatId: chatId, messageId: first.messageId),
              let thumb = doc.thumbnail else { throw ReadError.missing }
        library.thumbnails.record([first.messageId: thumb.file.remote.id], chatId: chatId)
        let path = try await td.download(fileId: thumb.file.id, priority: 8)
        return try Data(contentsOf: path)
    }

    /// The encrypted thumbnail (role `t`, one small file) downloaded whole by its stored remote id, then decrypted.
    /// Throws when the remote id can't be used (e.g. an expired file reference); the caller then reads it the long way.
    private func wholeEncryptedThumbnail(_ item: MediaItem) async throws -> Data {
        guard let master = library.keys?.master else { throw ReadError.locked }
        guard let part = parts(item, role: "t").first, parts(item, role: "t").count == 1, !part.fileId.isEmpty else { throw ReadError.missing }
        let cipher = try Data(contentsOf: try await td.download(remoteId: part.fileId, priority: 8))
        let reader = try CGFERandomReader(header: cipher.prefix(CGFELayout.headerLength), cipherSize: Int64(cipher.count), master: master)
        return try reader.read(0..<reader.layout.plaintextSize) { cipher.subdata(in: Int($0.lowerBound)..<Int($0.upperBound)) }
    }

    /// Fetches the start of a video, and its index when that sits at the end (iPhone camera videos keep `moov`
    /// after the media data), so playback begins without waiting when swiped to. Cancelling stops its download
    /// too, so it never takes bandwidth from the video on screen.
    func prefetch(_ item: MediaItem, role: String = "o", bytes: Int64 = 2 << 20) async {
        await withTaskCancellationHandler {
            let size = (try? await plaintextSize(item, role: role)) ?? 0
            // Same streaming path as the player, so opening this video shares the download instead of waiting
            // behind a separate low-priority one holding the file gate (AVPlayer timed out at 18 s).
            guard let head = try? await read(item, role: role, range: 0..<min(size, bytes), streaming: true), !Task.isCancelled,
                  let tail = MovieLayout.trailingIndexRange(prefix: head, totalSize: size), tail.count <= 4 << 20 else { return }
            _ = try? await read(item, role: role, range: tail, streaming: true)
        } onCancel: {
            self.stopDownloadsIfUnused(item, role: role)
        }
    }

    /// Looks up the resource's Telegram files right away, so the player's first read doesn't wait for it.
    /// Returns how long the lookup took (for the timing log).
    func warmUp(_ item: MediaItem, role: String) async -> TimeInterval {
        let started = Date()
        for part in parts(item, role: role) { _ = try? await tdFileId(for: part) }
        return Date().timeIntervalSince(started)
    }

    // MARK: - Open players

    func streamOpened(_ item: MediaItem, role: String) {
        lock.withLock { openStreams["\(item.id)/\(role)", default: 0] += 1 }
    }

    /// The last player of this video closed: stop TDLib downloading the rest of it (the streaming window asks for
    /// the whole file), so the next video gets the bandwidth.
    func streamClosed(_ item: MediaItem, role: String) {
        let key = "\(item.id)/\(role)"
        lock.withLock {
            openStreams[key, default: 1] -= 1
            if openStreams[key] ?? 0 <= 0 { openStreams[key] = nil }
        }
        stopDownloadsIfUnused(item, role: role)
    }

    private func stopDownloadsIfUnused(_ item: MediaItem, role: String) {
        let ids: [Int] = lock.withLock {
            guard openStreams["\(item.id)/\(role)"] == nil else { return [] }
            return parts(item, role: role).compactMap { fileIds[$0.messageId] }
        }
        for id in ids {
            td.cancelDownload(fileId: id)
            td.forgetStream(fileId: id)
        }
    }

    func forgetCaches() {
        lock.withLock {
            fileIds.removeAll()
            headers.removeAll()
        }
    }
}
