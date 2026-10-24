import Foundation
import CryptoKit

/// Format-1 caption metadata (docs/CLOUD_FORMAT.md §3.1). Field names are the wire keys.
public struct CaptionMeta: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case original = "o", pairedVideo = "pv", thumbnail = "t", smoothPreview = "sp", edited = "e" }
    public enum Kind: String, Codable, Sendable { case photo = "p", video = "v", live = "l" }

    public var v: Int = 1
    public var id: String
    public var r: Role
    public var k: Kind
    public var h: String
    public var n: String
    public var m: String?
    public var s: Int64
    public var t: Int64?
    public var tz: Int?
    public var g: [Double]?
    public var wh: [Int]?
    public var d: Double?
    public var c: String?
    public var hdr: Int?
    public var a: [String]?
    public var fav: Int?
    public var p: [Int64]?
    public var e: Int?
    public var src: String?
    /// Photos local identifier of the asset on the uploading device. iOS keeps it across app reinstalls on
    /// that device, so a restore links cloud items back to their photos exactly.
    public var l: String?
    /// On the original: 1 when the item also has an edited version (role `e`), so a restore can tell it's missing.
    public var ed: Int?

    public init(id: String, role: Role, kind: Kind, sha256: String, name: String, size: Int64) {
        self.id = id.lowercased()
        self.r = role
        self.k = kind
        self.h = sha256
        self.n = name
        self.s = size
    }

    /// Split info, if this message is one part of a split resource.
    public var part: (index: Int, count: Int, size: Int64)? {
        guard let p, p.count == 3 else { return nil }
        return (Int(p[0]), Int(p[1]), p[2])
    }

    public var isEncrypted: Bool { e == 1 }

    public var latitude: Double? { g.flatMap { $0.count >= 2 ? $0[0] : nil } }
    public var longitude: Double? { g.flatMap { $0.count >= 2 ? $0[1] : nil } }

    public static func roundedGPS(_ lat: Double, _ lon: Double, _ alt: Double? = nil) -> [Double] {
        func r6(_ x: Double) -> Double { (x * 1_000_000).rounded() / 1_000_000 }
        var out = [r6(lat), r6(lon)]
        if let alt { out.append((alt * 10).rounded() / 10) }
        return out
    }
}

public enum CaptionError: Error, Equatable {
    case notCloudGallery
    case malformed
    case unsupportedVersion(Int)
    case encryptedNeedsKey
}

/// Encodes/decodes captions: `CG1:{json}` (plain) or `CG1E:base64(nonce|ct|tag)` (E2E).
public enum CaptionCodec {
    public static let plainPrefix = "CG1:"
    public static let encryptedPrefix = "CG1E:"
    public static let maxLength = 1000

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    public static func json(_ meta: CaptionMeta) throws -> Data { try encoder.encode(meta) }

    /// Builds the caption, dropping optional fields until it fits in `maxLength` characters (§3.1).
    public static func encode(_ meta: CaptionMeta, captionKey: SymmetricKey? = nil) throws -> String {
        var m = meta
        for step in 0...4 {
            let caption = try render(m, captionKey: captionKey)
            if caption.count <= maxLength { return caption }
            switch step {
            case 0: m.a = nil
            case 1: m.c = nil
            case 2: m.l = nil
            case 3: m.n = truncatedName(m.n, by: caption.count - maxLength + 8)
            default: break
            }
        }
        return try render(m, captionKey: captionKey)
    }

    static func render(_ meta: CaptionMeta, captionKey: SymmetricKey?) throws -> String {
        let data = try json(meta)
        guard let key = captionKey else { return plainPrefix + String(decoding: data, as: UTF8.self) }
        return encryptedPrefix + (try E2EKeys.sealCaption(data, key: key)).base64EncodedString()
    }

    static func truncatedName(_ name: String, by excess: Int) -> String {
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        let keep = max(8, base.count - max(0, excess))
        let cut = String(base.prefix(keep))
        return ext.isEmpty ? cut : "\(cut).\(ext)"
    }

    public static func isCloudGallery(_ caption: String) -> Bool {
        caption.hasPrefix(plainPrefix) || caption.hasPrefix(encryptedPrefix)
    }

    public static func decode(_ caption: String, captionKey: SymmetricKey? = nil) throws -> CaptionMeta {
        let data: Data
        if caption.hasPrefix(plainPrefix) {
            data = Data(caption.dropFirst(plainPrefix.count).utf8)
        } else if caption.hasPrefix(encryptedPrefix) {
            guard let key = captionKey else { throw CaptionError.encryptedNeedsKey }
            guard let blob = Data(base64Encoded: String(caption.dropFirst(encryptedPrefix.count))) else { throw CaptionError.malformed }
            do { data = try E2EKeys.openCaption(blob, key: key) } catch { throw CaptionError.malformed }
        } else {
            throw CaptionError.notCloudGallery
        }
        let meta: CaptionMeta
        do { meta = try JSONDecoder().decode(CaptionMeta.self, from: data) } catch { throw CaptionError.malformed }
        guard meta.v == 1 else { throw CaptionError.unsupportedVersion(meta.v) }
        guard UUID(uuidString: meta.id) != nil, meta.h.count == 64 else { throw CaptionError.malformed }
        return meta
    }
}
