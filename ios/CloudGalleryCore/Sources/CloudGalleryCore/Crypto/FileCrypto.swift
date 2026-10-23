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
        let reader = try FileHandle(forReadingFrom: input)
        defer { try? reader.close() }
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }

        let salt = fileSalt
        var header = magic
        header.append(version)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(chunkSize).bigEndian) { Array($0) })
        header.append(salt)
        try writer.write(contentsOf: header)
        let key = fileKey(master: masterKey, salt: salt)

        var index: UInt64 = 0
        var current = try reader.read(upToCount: chunkSize) ?? Data()
        while true {
            let next = current.count == chunkSize ? (try reader.read(upToCount: chunkSize) ?? Data()) : Data()
            let isFinal = next.isEmpty
            let nonce = try nonces.map { try AES.GCM.Nonce(data: $0[Int(index)]) } ?? AES.GCM.Nonce()
            let box = try AES.GCM.seal(current, using: key, nonce: nonce, authenticating: aad(header: header, index: index, final: isFinal))
            guard let combined = box.combined else { throw CryptoError.badFormat }
            try writer.write(contentsOf: combined)
            if isFinal { break }
            current = next
            index += 1
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
