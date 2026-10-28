import Foundation
import CryptoKit

/// Geometry of a CGFE ciphertext (docs/CLOUD_FORMAT.md §6.2), for random-access reads.
public struct CGFELayout: Equatable, Sendable {
    public static let headerLength = 25
    public static let overhead = 28

    public let chunkSize: Int
    public let cipherSize: Int64

    public init(chunkSize: Int, cipherSize: Int64) {
        self.chunkSize = chunkSize
        self.cipherSize = cipherSize
    }

    var sealedChunk: Int64 { Int64(chunkSize + Self.overhead) }

    public var chunkCount: Int64 {
        let body = max(0, cipherSize - Int64(Self.headerLength))
        return max(1, (body + sealedChunk - 1) / sealedChunk)
    }

    public var plaintextSize: Int64 { cipherSize - Int64(Self.headerLength) - chunkCount * Int64(Self.overhead) }

    /// Byte range of sealed chunk `i` inside the ciphertext.
    public func cipherRange(ofChunk i: Int64) -> Range<Int64> {
        let start = Int64(Self.headerLength) + i * sealedChunk
        return start ..< min(cipherSize, start + sealedChunk)
    }

    /// Chunk indices needed for a plaintext range.
    public func chunks(coveringPlaintext range: Range<Int64>) -> ClosedRange<Int64> {
        let first = range.lowerBound / Int64(chunkSize)
        let last = max(first, (max(range.upperBound, range.lowerBound + 1) - 1) / Int64(chunkSize))
        return first ... min(last, chunkCount - 1)
    }

    public static func parseHeader(_ header: Data) throws -> (chunkSize: Int, salt: Data) {
        guard header.count >= headerLength else { throw CryptoError.truncated }
        let h = [UInt8](header.prefix(headerLength))
        guard Data(h[0..<4]) == FileCrypto.magic else { throw CryptoError.badFormat }
        guard h[4] == FileCrypto.version else { throw CryptoError.unsupportedVersion(h[4]) }
        let chunk = Int(h[5..<9].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        guard chunk >= 4096, chunk <= 64 << 20 else { throw CryptoError.badFormat }
        return (chunk, Data(h[9..<headerLength]))
    }
}

/// Decrypts arbitrary plaintext ranges of a CGFE file, fetching only the needed ciphertext.
public struct CGFERandomReader: Sendable {
    public let layout: CGFELayout
    let header: Data
    let key: SymmetricKey

    public init(header: Data, cipherSize: Int64, master: SymmetricKey) throws {
        let parsed = try CGFELayout.parseHeader(header)
        self.header = Data(header.prefix(CGFELayout.headerLength))
        self.layout = CGFELayout(chunkSize: parsed.chunkSize, cipherSize: cipherSize)
        self.key = FileCrypto.fileKey(master: master, salt: parsed.salt)
    }

    public func decryptChunk(_ index: Int64, sealed: Data) throws -> Data {
        let isFinal = index == layout.chunkCount - 1
        do {
            let box = try AES.GCM.SealedBox(combined: sealed)
            return try AES.GCM.open(box, using: key, authenticating: FileCrypto.aad(header: header, index: UInt64(index), final: isFinal))
        } catch {
            throw CryptoError.wrongPassphraseOrCorrupt
        }
    }

    /// Reads plaintext `range` using `fetch(cipherRange)` to obtain ciphertext bytes.
    public func read(_ range: Range<Int64>, fetch: (Range<Int64>) throws -> Data) throws -> Data {
        let clamped = max(0, range.lowerBound) ..< min(layout.plaintextSize, range.upperBound)
        guard !clamped.isEmpty else { return Data() }
        var out = Data()
        for i in layout.chunks(coveringPlaintext: clamped) {
            let plain = try decryptChunk(i, sealed: try fetch(layout.cipherRange(ofChunk: i)))
            let chunkStart = i * Int64(layout.chunkSize)
            let from = max(clamped.lowerBound, chunkStart) - chunkStart
            let to = min(clamped.upperBound, chunkStart + Int64(plain.count)) - chunkStart
            if to > from { out.append(plain[plain.startIndex + Int(from) ..< plain.startIndex + Int(to)]) }
        }
        return out
    }

    /// Like `read`, keeping decrypted chunks in `cache` under `file`. The player asks for 64–256 KB pieces of 1 MiB
    /// chunks, and each piece decrypted its whole chunk again (chunk 0 sixteen times as a video started); now only the
    /// chunks not in the cache are fetched, as one range, and decrypted.
    public func read(_ range: Range<Int64>, cache: DecryptedChunkCache, file: String,
                     fetch: (Range<Int64>) async throws -> Data) async throws -> Data {
        let clamped = max(0, range.lowerBound) ..< min(layout.plaintextSize, range.upperBound)
        guard !clamped.isEmpty else { return Data() }
        let needed = layout.chunks(coveringPlaintext: clamped)
        var plain: [Int64: Data] = [:]
        for i in needed { plain[i] = cache.chunk(file, i) }
        let missing = needed.filter { plain[$0] == nil }
        if let first = missing.first, let last = missing.last {
            let cipherRange = layout.cipherRange(ofChunk: first).lowerBound ..< layout.cipherRange(ofChunk: last).upperBound
            let cipher = try await fetch(cipherRange)
            guard Int64(cipher.count) >= Int64(cipherRange.count) else { throw CryptoError.truncated }
            for i in first ... last where plain[i] == nil {
                let cr = layout.cipherRange(ofChunk: i)
                let from = cipher.startIndex + Int(cr.lowerBound - cipherRange.lowerBound)
                let chunk = try decryptChunk(i, sealed: cipher.subdata(in: from ..< from + Int(cr.count)))
                cache.store(file, i, chunk)
                plain[i] = chunk
            }
        }
        var out = Data()
        for i in needed {
            guard let chunk = plain[i] else { continue }
            let chunkStart = i * Int64(layout.chunkSize)
            let from = max(clamped.lowerBound, chunkStart) - chunkStart
            let to = min(clamped.upperBound, chunkStart + Int64(chunk.count)) - chunkStart
            if to > from { out.append(chunk[chunk.startIndex + Int(from) ..< chunk.startIndex + Int(to)]) }
        }
        return out
    }
}

/// The last few decrypted CGFE chunks, least recently used dropped first. Small on purpose (a few MiB): it only has
/// to cover the pieces a player asks for around its playhead.
public final class DecryptedChunkCache: @unchecked Sendable {
    private struct Key: Hashable {
        let file: String
        let index: Int64
    }

    private let lock = NSLock()
    private let limit: Int
    private var chunks: [Key: Data] = [:]
    /// Least recently used first.
    private var order: [Key] = []
    private var bytes = 0

    public init(limit: Int = 4 << 20) {
        self.limit = limit
    }

    public var totalBytes: Int { lock.withLock { bytes } }

    public func chunk(_ file: String, _ index: Int64) -> Data? {
        lock.withLock {
            let key = Key(file: file, index: index)
            guard let data = chunks[key] else { return nil }
            order.removeAll { $0 == key }
            order.append(key)
            return data
        }
    }

    public func store(_ file: String, _ index: Int64, _ data: Data) {
        guard data.count <= limit else { return }
        lock.withLock {
            let key = Key(file: file, index: index)
            if let old = chunks.updateValue(data, forKey: key) {
                bytes -= old.count
                order.removeAll { $0 == key }
            }
            order.append(key)
            bytes += data.count
            while bytes > limit, !order.isEmpty {
                let dropped = order.removeFirst()
                bytes -= chunks.removeValue(forKey: dropped)?.count ?? 0
            }
        }
    }

    /// Drops every chunk of one file (its player closed).
    public func remove(file: String) {
        lock.withLock {
            for key in order where key.file == file { bytes -= chunks.removeValue(forKey: key)?.count ?? 0 }
            order.removeAll { $0.file == file }
        }
    }

    public func removeAll() {
        lock.withLock {
            chunks.removeAll()
            order.removeAll()
            bytes = 0
        }
    }
}

/// Maps a continuous stream onto fixed-size parts (docs/CLOUD_FORMAT.md §5).
public struct PartLayout: Equatable, Sendable {
    public static let mib: Int64 = 1 << 20
    public static let standardLimit: Int64 = 2000 * mib
    public static let premiumLimit: Int64 = 4000 * mib

    public let partSize: Int64
    public let totalSize: Int64

    public init(partSize: Int64, totalSize: Int64) {
        self.partSize = max(1, partSize)
        self.totalSize = totalSize
    }

    /// Part size for an account upload limit: limit − 1 MiB, rounded down to whole MiB.
    public static func partSize(forLimit limit: Int64) -> Int64 {
        ((limit - mib) / mib) * mib
    }

    public static func forUpload(size: Int64, limit: Int64) -> PartLayout {
        size > limit ? PartLayout(partSize: partSize(forLimit: limit), totalSize: size)
                     : PartLayout(partSize: max(size, 1), totalSize: size)
    }

    /// Free space a backup needs at its peak, before any margin: every exported file stays on disk until the item is
    /// done, and an encrypted or split file also writes one part beside its export (an unsplit plain file is a hard link).
    public static func spaceNeeded(exportSizes: [Int64], encrypted: Bool, limit: Int64) -> Int64 {
        let parts = exportSizes.map { size -> Int64 in
            let stream = encrypted ? FileCrypto.encryptedSize(plaintextSize: size) : size
            let layout = forUpload(size: stream, limit: limit)
            return encrypted || layout.isSplit ? layout.size(ofPart: 0) : 0
        }
        return exportSizes.reduce(0, +) + (parts.max() ?? 0)
    }

    public var partCount: Int { max(1, Int((totalSize + partSize - 1) / partSize)) }
    public var isSplit: Bool { partCount > 1 }

    public func size(ofPart i: Int) -> Int64 {
        min(partSize, totalSize - Int64(i) * partSize)
    }

    public struct Segment: Equatable, Sendable {
        public let part: Int
        public let offset: Int64
        public let length: Int64

        public init(part: Int, offset: Int64, length: Int64) {
            self.part = part
            self.offset = offset
            self.length = length
        }
    }

    /// Splits a stream range into per-part segments.
    public func segments(for range: Range<Int64>) -> [Segment] {
        var out: [Segment] = []
        var pos = max(0, range.lowerBound)
        let end = min(totalSize, range.upperBound)
        while pos < end {
            let part = Int(pos / partSize)
            let offset = pos - Int64(part) * partSize
            let length = min(end - pos, partSize - offset)
            out.append(Segment(part: part, offset: offset, length: length))
            pos += length
        }
        return out
    }
}
