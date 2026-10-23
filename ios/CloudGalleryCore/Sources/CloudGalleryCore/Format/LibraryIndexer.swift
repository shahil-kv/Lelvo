import Foundation

/// One CloudGallery document message read from the channel.
public struct CloudMessage: Equatable, Sendable {
    public let messageId: Int64
    public let meta: CaptionMeta
    /// TDLib persistent remote file id and unique id.
    public let fileId: String
    public let uniqueId: String
    /// Size of the stored document (part size for split files).
    public let size: Int64

    public init(messageId: Int64, meta: CaptionMeta, fileId: String, uniqueId: String, size: Int64) {
        self.messageId = messageId
        self.meta = meta
        self.fileId = fileId
        self.uniqueId = uniqueId
        self.size = size
    }
}

/// Rebuilds the item index from channel messages (docs/CLOUD_FORMAT.md §7).
public enum LibraryIndexer {
    public struct Result: Equatable {
        public var items: [MediaItem]
        /// Duplicate messages for an already-present (id, role, part); safe to delete.
        public var orphanMessageIds: [Int64]
    }

    public static func build(_ messages: [CloudMessage]) -> Result {
        var orphans: [Int64] = []
        // id → role → part index → message (lowest message id wins).
        var grouped: [String: [String: [Int: CloudMessage]]] = [:]
        for m in messages.sorted(by: { $0.messageId < $1.messageId }) {
            let part = m.meta.part?.index ?? 0
            if grouped[m.meta.id]?[m.meta.r.rawValue]?[part] != nil {
                orphans.append(m.messageId)
                continue
            }
            grouped[m.meta.id, default: [:]][m.meta.r.rawValue, default: [:]][part] = m
        }

        var items: [MediaItem] = []
        for (id, roles) in grouped {
            guard let anyMeta = roles.values.first?.values.first?.meta else { continue }
            let primary = roles["o"]?.values.min(by: { $0.messageId < $1.messageId })?.meta ?? anyMeta
            let kind: MediaKind = primary.k == .live ? .livePhoto : (primary.k == .video ? .video : .photo)
            var item = MediaItem(id: id, localIdentifier: nil, sha256: roles["o"] != nil ? primary.h : "",
                                 filename: primary.n, kind: kind, uti: nil,
                                 creationDate: primary.t.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                                 latitude: primary.latitude, longitude: primary.longitude,
                                 pixelWidth: primary.wh?.first ?? 0, pixelHeight: primary.wh.flatMap { $0.count > 1 ? $0[1] : nil } ?? 0,
                                 duration: primary.d, fileSize: primary.s, encrypted: primary.isEncrypted, status: .backedUp)
            item.mimeType = primary.m
            item.codec = primary.c
            item.hdr = primary.hdr
            item.tzOffsetMinutes = primary.tz
            item.albums = primary.a
            item.favorite = primary.fav == 1 ? true : nil
            item.sourceLocalIdentifier = primary.l
            item.hasEdit = (primary.ed == 1 || roles["e"] != nil) ? true : nil
            var hashes: [String: String] = [:]
            for (role, parts) in roles {
                let ordered = parts.sorted { $0.key < $1.key }.map(\.value)
                let expected = ordered.first?.meta.part?.count ?? 1
                let files = ordered.map { RemoteFile(messageId: $0.messageId, fileId: $0.fileId, fileUniqueId: $0.uniqueId, size: $0.size) }
                // Gaps in the part sequence mean an incomplete upload.
                let contiguous = parts.keys.sorted() == Array(0..<parts.count)
                item.setParts(files, role: role, expected: contiguous ? expected : expected + 1)
                hashes[role] = ordered.first?.meta.h
                if role == "e", let m = ordered.first?.meta {
                    item.editedFilename = m.n
                    item.editedSize = m.s
                }
                if role == "pv", let m = ordered.first?.meta {
                    item.pairedVideoFilename = m.n
                    item.pairedVideoSize = m.s
                }
            }
            item.roleHashes = hashes
            if !item.isCompleteInCloud {
                item.status = .failed
                item.lastError = "Incomplete in the cloud: a part is missing. Tap Retry to finish uploading it."
            }
            items.append(item)
        }
        items.sort { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        return Result(items: items, orphanMessageIds: orphans.sorted())
    }
}
