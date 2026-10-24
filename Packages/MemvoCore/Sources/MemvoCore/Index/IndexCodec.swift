import Foundation
import CryptoKit

/// Serialises the cloud index to the pinned, passphrase-encrypted blob and back.
///
/// Plaintext payload = `type byte ('I' index | 'M' manifest)` + LZFSE-compressed JSON.
/// The payload is sealed with `PassphraseBox`. If the sealed index exceeds what the Bot API can
/// download (20 MB), it is split into raw chunks and a small sealed manifest listing them is pinned.
public enum IndexCodec {
    public static let pinnedFileName = "cloudgallery-index.cgx"
    public static let caption = "#cloudgallery-index Encrypted Memvo index. Do not delete or unpin."
    /// Stay comfortably below the 20 MB Bot API download limit.
    public static let maxChunkSize = 19 * 1024 * 1024

    public enum Payload: Equatable {
        case index(CloudIndex)
        case manifest(IndexManifest)
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    public static func encodePayload(_ payload: Payload) throws -> Data {
        let (tag, json): (UInt8, Data)
        switch payload {
        case .index(let i): (tag, json) = (UInt8(ascii: "I"), try encoder.encode(i))
        case .manifest(let m): (tag, json) = (UInt8(ascii: "M"), try encoder.encode(m))
        }
        let compressed = try (json as NSData).compressed(using: .lzfse) as Data
        return Data([tag]) + compressed
    }

    public static func decodePayload(_ data: Data) throws -> Payload {
        guard let tag = data.first else { throw CryptoError.badFormat }
        let json: Data
        do {
            json = try (Data(data.dropFirst()) as NSData).decompressed(using: .lzfse) as Data
        } catch {
            throw CryptoError.badFormat
        }
        switch tag {
        case UInt8(ascii: "I"): return .index(try decoder.decode(CloudIndex.self, from: json))
        case UInt8(ascii: "M"): return .manifest(try decoder.decode(IndexManifest.self, from: json))
        default: throw CryptoError.badFormat
        }
    }

    public static func seal(_ payload: Payload, passphrase: String) throws -> Data {
        try PassphraseBox.seal(try encodePayload(payload), passphrase: passphrase)
    }

    public static func seal(_ payload: Payload, key: SymmetricKey, salt: Data, iterations: UInt32) throws -> Data {
        try PassphraseBox.seal(try encodePayload(payload), key: key, salt: salt, iterations: iterations)
    }

    public static func open(_ sealed: Data, passphrase: String) throws -> Payload {
        try decodePayload(try PassphraseBox.open(sealed, passphrase: passphrase))
    }

    public static func open(_ sealed: Data, key: SymmetricKey) throws -> Payload {
        try decodePayload(try PassphraseBox.open(sealed, key: key))
    }

    public static func split(_ data: Data, maxChunk: Int = maxChunkSize) -> [Data] {
        guard data.count > maxChunk else { return [data] }
        return stride(from: 0, to: data.count, by: maxChunk).map {
            Data(data[data.startIndex + $0 ..< data.startIndex + min($0 + maxChunk, data.count)])
        }
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
