import Foundation
import CryptoKit

/// A snapshot of the library index (docs/CLOUD_FORMAT.md §7.1): every Memvo message up to `upto`, as a scan would read
/// it, in one document. A new device reads the channel from the newest message back to the first snapshot and takes
/// the rest from it, instead of reading every message (100,000 photos are ~2,500 history requests). The channel stays
/// the truth: a full scan afterwards corrects anything deleted since the snapshot.
public enum IndexSnapshot {
    public static let plainPrefix = "CGX1:"
    public static let encryptedPrefix = "CGX1E:"
    static let captionAAD = "CGX1E"

    /// One message as a scan reads it.
    public struct Record: Codable, Equatable, Sendable {
        /// Message id, remote file id, unique file id, document size, caption metadata.
        public var m: Int64
        public var f: String
        public var u: String
        public var s: Int64
        public var c: CaptionMeta

        public init(_ message: CloudMessage) {
            m = message.messageId
            f = message.fileId
            u = message.uniqueId
            s = message.size
            c = message.meta
        }

        public var message: CloudMessage { CloudMessage(messageId: m, meta: c, fileId: f, uniqueId: u, size: s) }
    }

    public struct Body: Codable, Equatable, Sendable {
        public var v = 1
        /// The newest message id the snapshot covers.
        public var upto: Int64
        public var messages: [Record]
    }

    /// The snapshot message's caption.
    public struct Caption: Codable, Equatable, Sendable {
        public var v = 1
        public var upto: Int64
        /// Number of records, and SHA-256 (hex) of the document's plaintext (the compressed body).
        public var n: Int
        public var h: String

        public init(upto: Int64, n: Int, h: String) {
            self.upto = upto
            self.n = n
            self.h = h
        }
    }

    /// The snapshot of `items` (every message the index knows), up to `upto`.
    public static func body(items: [MediaItem], upto: Int64) -> Body {
        let records = items.filter { $0.cloudParts != nil }
            .flatMap { LibraryIndexer.knownMessages(of: $0, excluding: []) }
            .filter { $0.messageId <= upto }
            .sorted { $0.messageId < $1.messageId }
            .map(Record.init)
        return Body(upto: upto, messages: records)
    }

    /// Compact JSON, compressed with raw DEFLATE (RFC 1951).
    public static func encode(_ body: Body) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try (e.encode(body) as NSData).compressed(using: .zlib) as Data
    }

    public static func decode(_ data: Data) throws -> Body {
        let json = try (data as NSData).decompressed(using: .zlib) as Data
        let body = try JSONDecoder().decode(Body.self, from: json)
        guard body.v == 1 else { throw CaptionError.unsupportedVersion(body.v) }
        return body
    }

    public static func caption(_ caption: Caption, captionKey: SymmetricKey?) throws -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = try e.encode(caption)
        guard let key = captionKey else { return plainPrefix + String(decoding: json, as: UTF8.self) }
        return encryptedPrefix + (try E2EKeys.sealCaption(json, key: key, aad: captionAAD)).base64EncodedString()
    }

    public static func isSnapshot(_ caption: String) -> Bool {
        caption.hasPrefix(plainPrefix) || caption.hasPrefix(encryptedPrefix)
    }

    /// Nil when it isn't a snapshot caption this version reads (or the key doesn't open it).
    public static func parseCaption(_ text: String, captionKey: SymmetricKey?) -> Caption? {
        let json: Data
        if text.hasPrefix(plainPrefix) {
            json = Data(text.dropFirst(plainPrefix.count).utf8)
        } else if text.hasPrefix(encryptedPrefix), let key = captionKey,
                  let blob = Data(base64Encoded: String(text.dropFirst(encryptedPrefix.count))),
                  let opened = try? E2EKeys.openCaption(blob, key: key, aad: captionAAD) {
            json = opened
        } else {
            return nil
        }
        guard let caption = try? JSONDecoder().decode(Caption.self, from: json), caption.v == 1 else { return nil }
        return caption
    }
}
