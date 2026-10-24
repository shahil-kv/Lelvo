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
