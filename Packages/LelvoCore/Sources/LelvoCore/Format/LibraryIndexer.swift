import Foundation

/// One Lelvo document message read from the channel.
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

    /// The messages already known for `item` (minus `scanned`), as `build` needs them when a recent scan only sees an
    /// item's newer messages. Each role's caption comes from the item itself (that role's own name, size and hash),
    /// never from whichever message happened to be new: a fast version uploaded later must not become the original.
    public static func knownMessages(of item: MediaItem, excluding scanned: Set<Int64>) -> [CloudMessage] {
        let kind: CaptionMeta.Kind = item.kind == .livePhoto ? .live : (item.kind == .video ? .video : .photo)
        var out: [CloudMessage] = []
        for (role, parts) in item.cloudParts ?? [:] {
            guard let r = CaptionMeta.Role(rawValue: role) else { continue }
            let name: String, size: Int64
            switch role {
            case "o": (name, size) = (item.filename, item.fileSize)
            case "pv": (name, size) = (item.pairedVideoFilename ?? item.filename, item.pairedVideoSize ?? 0)
            case "e": (name, size) = (item.editedFilename ?? item.filename, item.editedSize ?? 0)
            default: (name, size) = (item.roleNames?[role] ?? item.filename, parts.reduce(0) { $0 + $1.size })
            }
            let hash = item.roleHashes?[role] ?? (role == "o" ? item.sha256 : String(repeating: "0", count: 64))
            var meta = CaptionMeta(id: item.id, role: r, kind: kind, sha256: hash, name: name, size: size)
            meta.m = item.mimeType
            meta.t = item.creationDate.map { Int64($0.timeIntervalSince1970) }
            meta.tz = item.tzOffsetMinutes
            if let lat = item.latitude, let lon = item.longitude { meta.g = [lat, lon] }
            if item.pixelWidth > 0 { meta.wh = [item.pixelWidth, item.pixelHeight] }
            meta.d = item.duration
            meta.c = item.codec
            meta.hdr = item.hdr
            meta.a = item.albums
            meta.fav = item.favorite == true ? 1 : nil
            meta.hid = item.hidden == true ? 1 : nil
            meta.l = item.sourceLocalIdentifier
            meta.ed = role == "o" && item.hasEdit == true ? 1 : nil
            meta.e = item.encrypted ? 1 : nil
            let count = item.expectedParts?[role] ?? parts.count
            for (i, f) in parts.enumerated() where !scanned.contains(f.messageId) {
                var m = meta
                m.p = count > 1 ? [Int64(i), Int64(count), parts.first?.size ?? 0] : nil
                out.append(CloudMessage(messageId: f.messageId, meta: m, fileId: f.fileId, uniqueId: f.fileUniqueId, size: f.size))
            }
        }
        return out
    }

    public enum DeleteOutcome: Equatable {
        case unchanged
        case update(MediaItem)
        case remove
    }

    /// What a full scan would make of `item` once the messages `deleted` are gone from the channel (another device
    /// deleted them): rebuilt from the messages left, or handled like an item that vanished. Phone-linked items are never
    /// removed; they become "not found" so they upload again.
    public static func afterDeleting(_ deleted: Set<Int64>, from item: MediaItem) -> DeleteOutcome {
        let owned = (item.cloudParts ?? [:]).values.flatMap { $0.map(\.messageId) }
        guard owned.contains(where: deleted.contains) else { return .unchanged }
        // Being uploaded by this device: the upload path owns its parts and checks them itself.
        guard item.status != .uploading, item.status != .queued else { return .unchanged }
        if var rebuilt = build(knownMessages(of: item, excluding: deleted)).items.first(where: { $0.id == item.id }) {
            rebuilt = rebuilt.keepingLocalState(from: item)
            if item.status == .trashed, rebuilt.status == .backedUp {
                rebuilt.status = .trashed
                rebuilt.trashedAt = item.trashedAt
            }
            return .update(rebuilt)
        }
        switch item.status {
        case .trashed:
            return .remove
        case .backedUp where item.localIdentifier == nil:
            return .remove
        case .backedUp:
            var missing = item
            missing.status = .failed
            missing.cloudParts = nil
            missing.lastError = "Not found in the Telegram channel any more. Tap Retry to upload it again."
            return .update(missing)
        default:
            return .unchanged
        }
    }

    /// Roles that only accompany an original; on their own they are leftovers.
    static let optionalOnlyRoles: Set<String> = ["d", "sp", "t", "ad", "ad2", "ra", "epv", "md"]

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
            // Only copies left (a screen copy, fast version or encrypted thumbnail) and no original: an older version
            // deleted the item and didn't know these roles. Nothing to show; offer them for removal with the duplicates.
            if roles["o"] == nil, Set(roles.keys).isSubset(of: optionalOnlyRoles) {
                orphans += roles.values.flatMap { $0.values.map(\.messageId) }
                continue
            }
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
            item.hidden = primary.hid == 1 ? true : nil
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
                if ["ad", "ad2", "ra", "epv", "md"].contains(role), let m = ordered.first?.meta {
                    var names = item.roleNames ?? [:]
                    names[role] = m.n
                    item.roleNames = names
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
