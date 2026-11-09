import Foundation
import CryptoKit

/// Recently Deleted across devices (docs/CLOUD_FORMAT.md §7.2). Each delete, recover or "delete now" adds one small
/// document to the channel; messages are never edited, so two devices can't overwrite each other. Telegram's message
/// ids order the notes and its message dates start the 30 days, so a device's clock can't change the result.
public enum TrashLog {
    public static let plainPrefix = "CGT1:"
    public static let encryptedPrefix = "CGT1E:"
    static let captionAAD = "CGT1E"

    public enum Op: String, Codable, Sendable {
        /// `gone` is no longer written. Test builds did, so it's still read, and such a note is removed.
        case delete = "del", recover = "recover", gone = "gone"
    }

    /// The document's content.
    public struct Body: Codable, Equatable, Sendable {
        public var v = 1
        public var op: Op
        public var ids: [String]

        public init(op: Op, ids: [String]) {
            self.op = op
            self.ids = ids
        }
    }

    /// The note message's caption.
    public struct Caption: Codable, Equatable, Sendable {
        public var v = 1
        /// Number of ids, and SHA-256 (hex) of the document's plaintext.
        public var n: Int
        public var h: String

        public init(n: Int, h: String) {
            self.n = n
            self.h = h
        }
    }

    /// A note as read from the channel.
    public struct Note: Codable, Equatable, Sendable {
        public var messageId: Int64
        public var date: Date
        public var op: Op
        public var ids: [String]

        public init(messageId: Int64, date: Date, op: Op, ids: [String]) {
            self.messageId = messageId
            self.date = date
            self.op = op
            self.ids = ids
        }
    }

    public static func encode(_ body: Body) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try e.encode(body)
    }

    /// Throws for anything this version doesn't understand (a newer version or an unknown action): such a note is ignored.
    public static func decode(_ data: Data) throws -> Body {
        let body = try JSONDecoder().decode(Body.self, from: data)
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

    /// The newest note for each item: the highest message id wins, whichever device sent it.
    public static func latest(_ notes: [Note]) -> [String: Note] {
        var result: [String: Note] = [:]
        for note in notes {
            for id in note.ids where (result[id]?.messageId ?? .min) < note.messageId { result[id] = note }
        }
        return result
    }

    public enum Action: Equatable {
        case none
        case trash(Date)
        case recover
        /// The messages are gone: forget the item.
        case remove
    }

    /// What the newest note means for `item`. Items still being uploaded wait: the note is kept and applied once they're
    /// done. `messagesSeen`: a full scan just read this item's messages, so a `gone` note can't be true (yet) and the
    /// item is only treated as deleted; when in doubt, keep data.
    public static func action(for item: MediaItem, note: Note, messagesSeen: Bool) -> Action {
        switch note.op {
        case .delete:
            return trashAction(item, note)
        case .recover:
            return item.status == .trashed ? .recover : .none
        case .gone:
            if messagesSeen { return trashAction(item, note) }
            return item.status == .backedUp || item.status == .trashed ? .remove : .none
        }
    }

    private static func trashAction(_ item: MediaItem, _ note: Note) -> Action {
        switch item.status {
        case .backedUp: return .trash(note.date)
        case .trashed: return item.trashedAt == note.date ? .none : .trash(note.date)
        default: return item.isStrandedInCloud ? .trash(note.date) : .none
        }
    }

    /// Applies an action other than `.remove`. Returns whether the item changed.
    @discardableResult
    public static func apply(_ action: Action, to item: inout MediaItem) -> Bool {
        switch action {
        case .trash(let date):
            // Not `CloudTrash.trash`: an item already in Recently Deleted takes the date all devices share.
            item.status = .trashed
            item.trashedAt = date
            return true
        case .recover:
            CloudTrash.recover(&item)
            return true
        case .none, .remove:
            return false
        }
    }

    /// Items in Recently Deleted from before notes existed: they get a note once, and so a fresh 30 days.
    public static func itemsNeedingANote(trashed: [MediaItem], notes: [Note], waiting: Set<String>) -> [MediaItem] {
        let newest = latest(notes)
        return trashed.filter { !waiting.contains($0.id) && newest[$0.id]?.op != .delete && newest[$0.id]?.op != .gone }
    }

    /// The notes a device must confirm are still in the channel: those that keep its items in Recently Deleted.
    public static func notesToConfirm(trashed: [MediaItem], notes: [Note], waiting: Set<String>) -> Set<Int64> {
        let newest = latest(notes)
        return Set(trashed.filter { !waiting.contains($0.id) }.compactMap { newest[$0.id]?.messageId })
    }

    /// Items in Recently Deleted that no note in the channel keeps there, because another device finished with the note
    /// while this one wasn't listening. Telegram decides what they are: messages gone means deleted for good, and
    /// messages still there means recovered. They never get a new note: that could delete a photo the user recovered.
    public static func uncovered(trashed: [MediaItem], notes: [Note], stillInChannel: Set<Int64>, waiting: Set<String>) -> [MediaItem] {
        let newest = latest(notes.filter { stillInChannel.contains($0.messageId) })
        return trashed.filter { item in
            guard !waiting.contains(item.id) else { return false }
            return newest[item.id].map { $0.op != .delete && $0.op != .gone } ?? true
        }
    }

    /// Whether Telegram has none of the item's messages left. One message going isn't enough: the rest are still the
    /// user's data. An item with no known messages says nothing, so it isn't gone.
    public static func allMessagesGone(_ item: MediaItem, existing: Set<Int64>) -> Bool {
        let ids = item.allMessageIds
        return !ids.isEmpty && !ids.contains(where: existing.contains)
    }

    /// Whether an expired item may really be deleted: its newest note must be a delete note, and nothing may be waiting
    /// to be sent for it. Anything else keeps the photo.
    public static func mayPurge(_ item: MediaItem, latest note: Note?, waiting: Set<String>) -> Bool {
        guard !waiting.contains(item.id), let note else { return false }
        return note.op == .delete || note.op == .gone
    }

    /// Notes that have done their job, so nothing stays in the channel. A delete note is finished when each of its items
    /// is deleted for good or has a newer note. A recover note is finished when no older delete note still lists its items.
    /// `known`: the items in this device's index.
    public static func notesToRemove(_ notes: [Note], known: [MediaItem]) -> [Note] {
        let newest = latest(notes)
        let present = Set(known.map(\.id))
        let unfinished = notes.filter { note in
            note.op == .delete && note.ids.contains { newest[$0]?.messageId == note.messageId && present.contains($0) }
        }
        return notes.filter { note in
            switch note.op {
            case .delete: return !unfinished.contains(note)
            case .gone: return true
            case .recover:
                let ids = Set(note.ids)
                return !unfinished.contains { $0.messageId < note.messageId && !ids.isDisjoint(with: $0.ids) }
            }
        }
    }

    /// How long to wait before the next note may go: 5 seconds so a burst of changes shares one note, and at least 10
    /// seconds between notes however someone taps. A minute was too slow to feel: a favorite changed on the phone took
    /// up to a minute to reach the Mac (#99). Six notes a minute at most stays far below what Telegram allows a chat,
    /// and a `FLOOD_WAIT` is still honoured exactly.
    public static let groupingDelay: TimeInterval = 5
    public static let minimumGap: TimeInterval = 10
    /// After a failed send (offline, Telegram busy), the next try waits a minute, not 10 seconds.
    public static let retryAfterFailure: TimeInterval = 60

    public static func sendDelay(lastSent: Date?, now: Date) -> TimeInterval {
        guard let lastSent else { return groupingDelay }
        return max(groupingDelay, lastSent.addingTimeInterval(minimumGap).timeIntervalSince(now))
    }

    /// The `lastSent` to keep after a failed send, so `sendDelay` waits `retryAfterFailure`.
    public static func lastSentAfterFailure(now: Date) -> Date {
        now.addingTimeInterval(retryAfterFailure - minimumGap)
    }

    /// Notes go as soon as they're finished, so a device that wasn't listening can miss a delete altogether. Only reading
    /// the whole channel finds that, so it does once a week.
    public static let fullScanEvery: TimeInterval = 7 * 24 * 3600

    public static func needsFullScan(lastFullScan: Date?, now: Date) -> Bool {
        guard let lastFullScan else { return true }
        return now.timeIntervalSince(lastFullScan) > fullScanEvery
    }
}
