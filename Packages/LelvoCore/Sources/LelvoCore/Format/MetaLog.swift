import Foundation
import CryptoKit

/// Favorites and albums across devices (docs/CLOUD_FORMAT.md §7.3). A change made after an item was backed up adds one
/// small document to the channel, for many items at once; messages are never edited, so two devices can't overwrite
/// each other. For each item, its favorite and its membership of each album follow the note with the highest message id.
///
/// Its own caption prefix, not Recently Deleted's: readers from before these notes don't download them at all.
public enum MetaLog {
    public static let plainPrefix = "CGM1:"
    public static let encryptedPrefix = "CGM1E:"
    static let captionAAD = "CGM1E"

    public enum Op: String, Codable, Sendable, CaseIterable {
        case favorite = "fav", unfavorite = "unfav", albumAdd = "album-add", albumRemove = "album-remove"

        var isAlbum: Bool { self == .albumAdd || self == .albumRemove }
        var value: Bool { self == .favorite || self == .albumAdd }
    }

    /// What a note sets: the favorite, or membership of one album (by name, as Photos shows it).
    public enum Key: Hashable, Codable, Sendable {
        case favorite
        case album(String)

        /// For the index's outbox.
        public var stored: String {
            switch self {
            case .favorite: return "fav"
            case .album(let name): return "a:" + name
            }
        }

        public init?(stored: String) {
            if stored == "fav" { self = .favorite } else if stored.hasPrefix("a:"), stored.count > 2 {
                self = .album(String(stored.dropFirst(2)))
            } else { return nil }
        }
    }

    /// The document's content. `album` only with the album ops.
    public struct Body: Codable, Equatable, Sendable {
        public var v = 1
        public var op: Op
        public var ids: [String]
        public var album: String?

        public init(op: Op, ids: [String], album: String? = nil) {
            self.op = op
            self.ids = ids
            self.album = album
        }

        var key: Key? {
            if op.isAlbum {
                guard let album, let name = MetaLog.albumName(album) else { return nil }
                return .album(name)
            }
            return album == nil ? .favorite : nil
        }
    }

    public typealias Caption = TrashLog.Caption

    /// A note as read from the channel.
    public struct Note: Codable, Equatable, Sendable {
        public var messageId: Int64
        public var date: Date
        public var op: Op
        public var ids: [String]
        public var album: String?

        public init(messageId: Int64, date: Date, op: Op, ids: [String], album: String? = nil) {
            self.messageId = messageId
            self.date = date
            self.op = op
            self.ids = ids
            self.album = album
        }

        public var key: Key? { Body(op: op, ids: [], album: album).key }
    }

    /// Album names as Photos keeps them: surrounding spaces don't make a different album. Empty is no album.
    public static func albumName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    public static func encode(_ body: Body) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try e.encode(body)
    }

    /// Throws for anything this version doesn't understand (a newer version, an unknown action, an album op without an
    /// album): such a note is ignored, which changes nothing.
    public static func decode(_ data: Data) throws -> Body {
        let body = try JSONDecoder().decode(Body.self, from: data)
        guard body.v == 1 else { throw CaptionError.unsupportedVersion(body.v) }
        guard body.key != nil else { throw CaptionError.unsupportedVersion(body.v) }
        return body
    }

    public static func caption(_ caption: Caption, captionKey: SymmetricKey?) throws -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = try e.encode(caption)
        guard let key = captionKey else { return plainPrefix + String(decoding: json, as: UTF8.self) }
        return encryptedPrefix + (try E2EKeys.sealCaption(json, key: key, aad: captionAAD)).base64EncodedString()
    }

    public static func isNote(_ caption: String) -> Bool {
        caption.hasPrefix(plainPrefix) || caption.hasPrefix(encryptedPrefix)
    }

    /// Nil when it isn't a note caption this version reads (or the key doesn't open it).
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

    /// Checks a downloaded document against its caption. Nil when anything is off: a damaged note changes nothing.
    public static func read(_ data: Data, caption: Caption) -> Body? {
        guard IndexCodec.sha256Hex(data) == caption.h, let body = try? decode(data), body.ids.count == caption.n else { return nil }
        return body
    }

    // MARK: - Which note wins

    /// For each item and key, the value of the note with the highest message id, and that id.
    public static func latest(_ notes: [Note]) -> [String: [Key: (value: Bool, messageId: Int64)]] {
        var result: [String: [Key: (value: Bool, messageId: Int64)]] = [:]
        for note in notes {
            guard let key = note.key else { continue }
            for id in note.ids where (result[id]?[key]?.messageId ?? .min) < note.messageId {
                result[id, default: [:]][key] = (note.op.value, note.messageId)
            }
        }
        return result
    }

    /// Sets the item's favorite and albums to `values`. Albums not named keep what the backup recorded. Returns whether
    /// anything changed.
    @discardableResult
    public static func apply(_ values: [Key: Bool], to item: inout MediaItem) -> Bool {
        var changed = false
        var albums = item.albums ?? []
        for (key, value) in values.sorted(by: { $0.key.stored < $1.key.stored }) {
            switch key {
            case .favorite:
                if item.favorite != value { item.favorite = value; changed = true }
            case .album(let name):
                let present = albums.contains(name)
                if value && !present { albums.append(name); changed = true }
                if !value && present { albums.removeAll { $0 == name }; changed = true }
            }
        }
        if changed { item.albums = albums.isEmpty ? nil : albums }
        return changed
    }

    /// What the notes say about one item, with changes this device hasn't sent yet on top: they're newer than any note.
    public static func values(for id: String, latest: [String: [Key: (value: Bool, messageId: Int64)]],
                              waiting: [Key: Bool]?) -> [Key: Bool] {
        var values = (latest[id] ?? [:]).mapValues(\.value)
        for (key, value) in waiting ?? [:] { values[key] = value }
        return values
    }

    // MARK: - Sending

    /// Turns waiting changes (item → key → value) into notes: one per action and album, ids sorted. Many photos
    /// favorited in a minute share one note.
    public static func bodies(for changes: [String: [Key: Bool]]) -> [Body] {
        var grouped: [Key: [Bool: [String]]] = [:]
        for (id, keys) in changes {
            for (key, value) in keys { grouped[key, default: [:]][value, default: []].append(id) }
        }
        var bodies: [Body] = []
        for (key, byValue) in grouped {
            for (value, ids) in byValue {
                let sorted = ids.sorted()
                for start in stride(from: 0, to: sorted.count, by: maxIdsPerNote) {
                    let chunk = Array(sorted[start..<min(start + maxIdsPerNote, sorted.count)])
                    switch key {
                    case .favorite: bodies.append(Body(op: value ? .favorite : .unfavorite, ids: chunk))
                    case .album(let name): bodies.append(Body(op: value ? .albumAdd : .albumRemove, ids: chunk, album: name))
                    }
                }
            }
        }
        return bodies.sorted { ($0.album ?? "", $0.op.rawValue, $0.ids.first ?? "") < ($1.album ?? "", $1.op.rawValue, $1.ids.first ?? "") }
    }

    /// The most ids one note carries, so its document and caption stay small. A bigger change goes as several notes.
    public static let maxIdsPerNote = 2000

    // MARK: - Cleaning up

    /// Notes that no longer decide anything: every item they list has a newer note for the same key. Deleting them
    /// changes nothing, so the channel doesn't fill up. A note that still decides one item stays, whole.
    public static func notesToRemove(_ notes: [Note]) -> [Note] {
        let newest = latest(notes)
        return notes.filter { note in
            guard let key = note.key else { return true }
            return note.ids.allSatisfy { (newest[$0]?[key]?.messageId ?? .min) > note.messageId }
        }
    }

    /// With this many notes left, a device writes the current state as fresh notes and removes the old ones, so a library
    /// changed a little every day doesn't keep a note for each day.
    public static let compactAbove = 200

    /// The current state as notes to send before removing `notes`: every item and key the notes still decide.
    public static func compacted(_ notes: [Note]) -> [Body] {
        let state = latest(notes).mapValues { $0.mapValues(\.value) }
        return bodies(for: state)
    }
}
