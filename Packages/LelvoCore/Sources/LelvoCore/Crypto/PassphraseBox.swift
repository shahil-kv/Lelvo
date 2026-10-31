import Foundation
import CryptoKit
import Security

/// Passphrase-encrypted container used for the cloud index, manifest and Files export.
///
/// Layout: `"CGIX" | version (1) | PBKDF2 iterations (UInt32 BE) | salt (16) | AES-GCM combined (nonce 12 | ciphertext | tag 16)`.
/// The header is authenticated as additional data, so tampering with iterations or salt is detected.
public enum PassphraseBox {
    public static let magic = Data("CGIX".utf8)
    public static let version: UInt8 = 1
    static let headerLength = 4 + 1 + 4 + KeyDerivation.saltLength

    public static func seal(_ plaintext: Data, passphrase: String,
                            iterations: UInt32 = KeyDerivation.defaultIterations,
                            salt: Data = KeyDerivation.randomSalt()) throws -> Data {
        let key = try KeyDerivation.symmetricKey(passphrase: passphrase, salt: salt, iterations: iterations)
        return try seal(plaintext, key: key, salt: salt, iterations: iterations)
    }

    /// Seals with an already-derived key (lets callers cache the expensive PBKDF2 result).
    public static func seal(_ plaintext: Data, key: SymmetricKey, salt: Data, iterations: UInt32) throws -> Data {
        precondition(salt.count == KeyDerivation.saltLength)
        var header = magic
        header.append(version)
        header.append(contentsOf: withUnsafeBytes(of: iterations.bigEndian) { Array($0) })
        header.append(salt)
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: header)
        guard let combined = box.combined else { throw CryptoError.badFormat }
        return header + combined
    }

    public struct Header: Equatable {
        public let version: UInt8
        public let iterations: UInt32
        public let salt: Data
    }

    public static func header(of data: Data) throws -> Header {
        guard data.count >= headerLength + 12 + 16 else { throw CryptoError.truncated }
        let bytes = [UInt8](data.prefix(headerLength))
        guard Data(bytes[0..<4]) == magic else { throw CryptoError.badFormat }
        guard bytes[4] == version else { throw CryptoError.unsupportedVersion(bytes[4]) }
        let iterations = bytes[5..<9].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard iterations >= 1_000 else { throw CryptoError.badFormat }
        return Header(version: bytes[4], iterations: iterations, salt: Data(bytes[9..<headerLength]))
    }

    public static func open(_ data: Data, passphrase: String) throws -> Data {
        let h = try header(of: data)
        let key = try KeyDerivation.symmetricKey(passphrase: passphrase, salt: h.salt, iterations: h.iterations)
        return try open(data, key: key)
    }

    public static func open(_ data: Data, key: SymmetricKey) throws -> Data {
        _ = try header(of: data)
        let headerBytes = data.prefix(headerLength)
        do {
            let box = try AES.GCM.SealedBox(combined: data.dropFirst(headerLength))
            return try AES.GCM.open(box, using: key, authenticating: headerBytes)
        } catch {
            throw CryptoError.wrongPassphraseOrCorrupt
        }
    }
}
