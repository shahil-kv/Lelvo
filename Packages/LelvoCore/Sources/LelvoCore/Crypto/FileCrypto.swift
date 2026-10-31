import Foundation
import CryptoKit

/// Chunked AES-GCM for end-to-end encrypted originals and thumbnails.
///
/// Layout: `"CGFE" | version (1) | chunk size (UInt32 BE) | file salt (16)` followed by chunks of
/// `nonce (12) | ciphertext (≤ chunk size) | tag (16)`. Each chunk authenticates the header, its index and
/// a final-chunk flag, so reordering, truncation or appending is detected. The per-file key is
/// HKDF-SHA256(master key, file salt), so the master key never encrypts data directly.
public enum FileCrypto {
    public static let magic = Data("CGFE".utf8)
    public static let version: UInt8 = 1
    public static let defaultChunkSize = 1 << 20
    /// Fast versions (role `sp`) are streamed: the player can't show anything until the first whole chunk has arrived
    /// and been checked, which took 1.5–3.5 s for 1 MiB at Telegram's speed for accounts without Premium. 256 KiB
    /// starts four times sooner for 28 bytes more per chunk. Readers take the size from each file's header.
    public static let fastVersionChunkSize = 256 << 10
    static let headerLength = 4 + 1 + 4 + 16
    static let overheadPerChunk = 12 + 16

    public static func isEncrypted(_ prefix: Data) -> Bool { prefix.prefix(4) == magic }

    /// Size of the ciphertext produced for a plaintext of `size` bytes.
    public static func encryptedSize(plaintextSize size: Int64, chunkSize: Int = defaultChunkSize) -> Int64 {
        let chunks = max(1, (size + Int64(chunkSize) - 1) / Int64(chunkSize))
        return Int64(headerLength) + size + chunks * Int64(overheadPerChunk)
    }

    static func fileKey(master: SymmetricKey, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: salt,
                               info: Data("CloudGallery file v1".utf8), outputByteCount: 32)
    }

    static func aad(header: Data, index: UInt64, final: Bool) -> Data {
        var d = header
        d.append(contentsOf: withUnsafeBytes(of: index.bigEndian) { Array($0) })
        d.append(final ? 1 : 0)
        return d
    }

    public static func encrypt(input: URL, output: URL, masterKey: SymmetricKey, chunkSize: Int = defaultChunkSize) throws {
        try encrypt(input: input, output: output, masterKey: masterKey, chunkSize: chunkSize, fileSalt: KeyDerivation.randomSalt(), nonces: nil)
    }

    /// `fileSalt`/`nonces` are fixed only when generating test vectors.
    static func encrypt(input: URL, output: URL, masterKey: SymmetricKey, chunkSize: Int, fileSalt: Data, nonces: [Data]?) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: output.path) { try fm.removeItem(at: output) }
        fm.createFile(atPath: output.path, contents: nil)
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }
        let encryptor = try Encryptor(input: input, masterKey: masterKey, chunkSize: chunkSize, fileSalt: fileSalt, nonces: nonces)
        while true {
            let bytes = try encryptor.read(upToCount: 8 << 20)
            if bytes.isEmpty { break }
            try writer.write(contentsOf: bytes)
        }
    }

    /// Where an interrupted encrypted upload stopped: enough to make the rest of the same ciphertext. Chunk boundaries
    /// don't line up with part boundaries (the header shifts them by 25 bytes), so the chunk crossing the cut is sealed
    /// again with its old nonce, which gives the very same bytes. That is only safe for the very same plaintext: reusing
    /// a GCM nonce for other bytes gives the key away, hence `plaintextHash`. Nothing here is secret: the salt and
    /// nonces are stored in the clear in the uploaded parts.
    public struct ResumePoint: Codable, Equatable, Sendable {
        /// Ciphertext bytes already uploaded.
        public let cipherOffset: Int64
        public let chunkSize: Int
        public let fileSalt: Data
        /// Nonce of the chunk crossing `cipherOffset`; nil when a chunk starts exactly there.
        public let nonce: Data?
        /// SHA-256 (hex) of the plaintext, set by the caller and checked before resuming.
        public let plaintextHash: String

        public init(cipherOffset: Int64, chunkSize: Int, fileSalt: Data, nonce: Data?, plaintextHash: String) {
            self.cipherOffset = cipherOffset
            self.chunkSize = chunkSize
            self.fileSalt = fileSalt
            self.nonce = nonce
            self.plaintextHash = plaintextHash
        }

        /// True when the parts confirmed so far (their sizes, in order) end exactly here and the file and its
        /// encryption are the same as before. Anything else starts over.
        public func continues(partSizes: [Int64], layout: PartLayout, chunkSize: Int, plaintextHash: String) -> Bool {
            guard !partSizes.isEmpty, partSizes.count < layout.partCount,
                  chunkSize == self.chunkSize, plaintextHash == self.plaintextHash, fileSalt.count == 16,
                  partSizes.enumerated().allSatisfy({ $0.element == layout.size(ofPart: $0.offset) }) else { return false }
            return cipherOffset == partSizes.reduce(0, +)
        }
    }

    /// The CGFE ciphertext of a file, produced in order as it's read, so a caller can write it straight into split parts
    /// (one part on disk at a time) instead of encrypting a whole copy first: a 4 GB video in an encrypted library needed
    /// about 10 GB free. The bytes are exactly those `encrypt(input:output:…)` writes.
    public final class Encryptor {
        private let reader: FileHandle
        private let header: Data
        private let fileSalt: Data
        private let key: SymmetricKey
        private let chunkSize: Int
        private let nonces: [Data]?
        private var index: UInt64 = 0
        /// Ciphertext bytes handed out so far, counted from the start of the file.
        private var offset: Int64 = 0
        /// When resuming: the nonce for the first chunk sealed, and how many of its bytes were uploaded already.
        private var resumeNonce: AES.GCM.Nonce?
        private var resumeSkip = 0
        /// Sealed bytes not handed out yet, from `pendingStart`.
        private var pending: Data
        private var pendingStart = 0
        private var current: Data?
        private var finished = false

        /// Size of the whole ciphertext.
        public let cipherSize: Int64

        public convenience init(input: URL, masterKey: SymmetricKey, chunkSize: Int = defaultChunkSize) throws {
            try self.init(input: input, masterKey: masterKey, chunkSize: chunkSize, fileSalt: KeyDerivation.randomSalt(), nonces: nil)
        }

        /// Continues the ciphertext of an earlier `Encryptor` from `point`: the bytes read are exactly those that
        /// encryptor would have produced after `point.cipherOffset`, apart from the nonces of whole chunks, which are new.
        /// The caller checks that `input` is the same plaintext (`point.plaintextHash`).
        public convenience init(input: URL, masterKey: SymmetricKey, resumingAt point: ResumePoint) throws {
            try self.init(input: input, masterKey: masterKey, chunkSize: point.chunkSize, fileSalt: point.fileSalt, nonces: nil)
            try resume(at: point)
        }

        init(input: URL, masterKey: SymmetricKey, chunkSize: Int, fileSalt: Data, nonces: [Data]?) throws {
            reader = try FileHandle(forReadingFrom: input)
            let size = Int64(try reader.seekToEnd())
            try reader.seek(toOffset: 0)
            cipherSize = FileCrypto.encryptedSize(plaintextSize: size, chunkSize: chunkSize)
            var header = magic
            header.append(version)
            header.append(contentsOf: withUnsafeBytes(of: UInt32(chunkSize).bigEndian) { Array($0) })
            header.append(fileSalt)
            self.header = header
            self.fileSalt = fileSalt
            self.key = fileKey(master: masterKey, salt: fileSalt)
            self.chunkSize = chunkSize
            self.nonces = nonces
            pending = header
        }

        /// Fixed salt and nonces, for tests only.
        public static func forTesting(input: URL, masterKey: SymmetricKey, chunkSize: Int, fileSalt: Data, nonces: [Data]) throws -> Encryptor {
            try Encryptor(input: input, masterKey: masterKey, chunkSize: chunkSize, fileSalt: fileSalt, nonces: nonces)
        }

        /// Same as `init(input:masterKey:resumingAt:)` with fixed nonces for the chunks after the cut, for tests only.
        public static func forTesting(input: URL, masterKey: SymmetricKey, resumingAt point: ResumePoint, nonces: [Data]) throws -> Encryptor {
            let encryptor = try Encryptor(input: input, masterKey: masterKey, chunkSize: point.chunkSize, fileSalt: point.fileSalt, nonces: nonces)
            try encryptor.resume(at: point)
            return encryptor
        }

        deinit { try? reader.close() }

        /// Where the bytes read so far end, to resume from there later.
        public func resumePoint(plaintextHash: String) -> ResumePoint {
            // Inside a sealed chunk, `pending` holds it and starts with its nonce. Resumed with nothing read yet, the
            // cut is still the earlier point's.
            let insideChunk = offset > Int64(headerLength) && pendingStart < pending.count
            let nonce = resumeNonce.map { $0.withUnsafeBytes { Data($0) } } ?? (insideChunk ? Data(pending.prefix(12)) : nil)
            return ResumePoint(cipherOffset: offset, chunkSize: chunkSize, fileSalt: fileSalt, nonce: nonce,
                               plaintextHash: plaintextHash)
        }

        private func resume(at point: ResumePoint) throws {
            guard point.cipherOffset >= 0, point.cipherOffset <= cipherSize else { throw CryptoError.badFormat }
            offset = point.cipherOffset
            if point.cipherOffset == cipherSize {
                pending = Data()
                pendingStart = 0
                finished = true
                return
            }
            if point.cipherOffset < Int64(headerLength) {
                pendingStart = Int(point.cipherOffset)
                return
            }
            let sealed = Int64(chunkSize + overheadPerChunk)
            let into = point.cipherOffset - Int64(headerLength)
            index = UInt64(into / sealed)
            resumeSkip = Int(into % sealed)
            if resumeSkip > 0 {
                guard let nonce = point.nonce else { throw CryptoError.badFormat }
                resumeNonce = try AES.GCM.Nonce(data: nonce)
            }
            try reader.seek(toOffset: index * UInt64(chunkSize))
            pending = Data()
            pendingStart = 0
        }

        /// Up to `count` more ciphertext bytes; empty once everything was read.
        public func read(upToCount count: Int) throws -> Data {
            var out = Data()
            while out.count < count {
                if pendingStart == pending.count {
                    guard try sealNext() else { break }
                }
                let n = min(count - out.count, pending.count - pendingStart)
                out.append(pending[pending.startIndex + pendingStart ..< pending.startIndex + pendingStart + n])
                pendingStart += n
            }
            offset += Int64(out.count)
            return out
        }

        /// Seals the next chunk into `pending`; false at the end. A chunk is final when nothing follows it, which is only
        /// known after reading ahead, as in `encrypt`.
        private func sealNext() throws -> Bool {
            guard !finished else { return false }
            let chunk = try current ?? (reader.read(upToCount: chunkSize) ?? Data())
            let next = chunk.count == chunkSize ? (try reader.read(upToCount: chunkSize) ?? Data()) : Data()
            let isFinal = next.isEmpty
            let nonce = try resumeNonce ?? nonces.map { try AES.GCM.Nonce(data: $0[Int(index)]) } ?? AES.GCM.Nonce()
            let box = try AES.GCM.seal(chunk, using: key, nonce: nonce, authenticating: aad(header: header, index: index, final: isFinal))
            guard let combined = box.combined else { throw CryptoError.badFormat }
            pending = combined
            pendingStart = resumeSkip
            resumeNonce = nil
            resumeSkip = 0
            current = next
            index += 1
            finished = isFinal
            return true
        }
    }

    public static func decrypt(input: URL, output: URL, masterKey: SymmetricKey) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: output.path) { try fm.removeItem(at: output) }
        fm.createFile(atPath: output.path, contents: nil)
        let reader = try FileHandle(forReadingFrom: input)
        defer { try? reader.close() }
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }

        guard let header = try reader.read(upToCount: headerLength), header.count == headerLength else { throw CryptoError.truncated }
        let h = [UInt8](header)
        guard Data(h[0..<4]) == magic else { throw CryptoError.badFormat }
        guard h[4] == version else { throw CryptoError.unsupportedVersion(h[4]) }
        let chunkSize = Int(h[5..<9].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        guard chunkSize >= 1, chunkSize <= 64 << 20 else { throw CryptoError.badFormat }
        let key = fileKey(master: masterKey, salt: Data(h[9..<headerLength]))
        let sealedChunk = chunkSize + overheadPerChunk

        var index: UInt64 = 0
        var current = try reader.read(upToCount: sealedChunk) ?? Data()
        while true {
            guard current.count >= overheadPerChunk else { throw CryptoError.truncated }
            let next = current.count == sealedChunk ? (try reader.read(upToCount: sealedChunk) ?? Data()) : Data()
            let isFinal = next.isEmpty
            do {
                let box = try AES.GCM.SealedBox(combined: current)
                let plain = try AES.GCM.open(box, using: key, authenticating: aad(header: Data(h), index: index, final: isFinal))
                try writer.write(contentsOf: plain)
            } catch {
                throw CryptoError.wrongPassphraseOrCorrupt
            }
            if isFinal { break }
            current = next
            index += 1
        }
    }

    public static func encrypt(data: Data, masterKey: SymmetricKey) throws -> Data {
        try roundTripViaFiles(data) { try encrypt(input: $0, output: $1, masterKey: masterKey) }
    }

    /// Deterministic encryption for cross-platform test vectors only.
    public static func encryptForTesting(data: Data, masterKey: SymmetricKey, chunkSize: Int, fileSalt: Data, nonces: [Data]) throws -> Data {
        try roundTripViaFiles(data) { try encrypt(input: $0, output: $1, masterKey: masterKey, chunkSize: chunkSize, fileSalt: fileSalt, nonces: nonces) }
    }

    public static func decrypt(data: Data, masterKey: SymmetricKey) throws -> Data {
        try roundTripViaFiles(data) { try decrypt(input: $0, output: $1, masterKey: masterKey) }
    }

    private static func roundTripViaFiles(_ data: Data, _ body: (URL, URL) throws -> Void) throws -> Data {
        let dir = FileManager.default.temporaryDirectory
        let a = dir.appendingPathComponent(UUID().uuidString), b = dir.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        try data.write(to: a)
        try body(a, b)
        return try Data(contentsOf: b)
    }
}
