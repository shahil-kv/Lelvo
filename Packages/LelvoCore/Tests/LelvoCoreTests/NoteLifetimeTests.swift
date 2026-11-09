import Testing
import Foundation
@testable import LelvoCore

/// A year of use on two devices, to prove notes in the channel stay few and leave nothing behind (#99): each day brings
/// random changes, and the clean-up each device runs on open must keep every item's state while removing every note that
/// no longer decides anything.
@Suite struct NoteLifetimeTests {
    /// Same numbers every run.
    struct Random {
        var state: UInt64
        mutating func next(_ n: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(n))
        }
    }

    /// Heavy use (about 20 changes a day) keeps the channel at the compaction limit at most, never above it.
    @Test(arguments: [1, 2] as [UInt64])
    func favoritesAndAlbumsNotesStayFewForAYear(seed: UInt64) {
        var random = Random(state: seed)
        let start = Date(timeIntervalSince1970: 1_000 * 86400)
        let albums = ["Goa Trip", "Family", "Work", "Pets", "Food"]
        var known = Set((0..<3_000).map { "i\($0)" })
        var next = 3_000
        var truth: [String: [MetaLog.Key: Bool]] = [:]
        var notes: [MetaLog.Note] = []
        var messageId: Int64 = 0
        var most = 0

        func send(_ bodies: [MetaLog.Body], on day: Date) {
            for body in bodies {
                messageId += 1
                notes.append(MetaLog.Note(messageId: messageId, date: day, op: body.op, ids: body.ids, album: body.album))
            }
        }

        for dayNumber in 0..<365 {
            let day = start.addingTimeInterval(TimeInterval(dayNumber) * 86400)
            // Today's changes, from either device: favorites, album adds and removes, a whole album deleted now and then.
            var changes: [String: [MetaLog.Key: Bool]] = [:]
            let pool = Array(known)
            for _ in 0..<random.next(40) {
                let id = pool[random.next(pool.count)]
                let key: MetaLog.Key = random.next(2) == 0 ? .favorite : .album(albums[random.next(albums.count)])
                changes[id, default: [:]][key] = random.next(2) == 0
            }
            if random.next(30) == 0 {
                let album = MetaLog.Key.album(albums[random.next(albums.count)])
                for (id, keys) in truth where keys[album] == true && known.contains(id) { changes[id, default: [:]][album] = false }
            }
            send(MetaLog.bodies(for: changes), on: day)
            for (id, keys) in changes { truth[id, default: [:]].merge(keys) { $1 } }

            // New photos backed up, some deleted for good (their Recently Deleted days are over).
            for _ in 0..<random.next(10) { known.insert("i\(next)"); next += 1 }
            for _ in 0..<random.next(5) { if let gone = known.randomElement(using: &random) { known.remove(gone); truth[gone] = nil } }

            // What `MetaSync.onOpen` does: compact when long, then remove what decides nothing.
            if notes.count > MetaLog.compactAbove {
                let fresh = MetaLog.compacted(notes, known: known)
                if fresh.count * 2 < notes.count { send(fresh, on: day) }
            }
            let finished = Set(MetaLog.notesToRemove(notes, known: known, now: day).map(\.messageId))
            notes.removeAll { finished.contains($0.messageId) }
            most = max(most, notes.count)

            // Clean-up never changes what an item shows.
            let latest = MetaLog.latest(notes)
            for (id, keys) in truth where known.contains(id) {
                for (key, value) in keys { #expect(latest[id]?[key]?.value == value, "Day \(dayNumber): \(id) lost \(key.stored)") }
            }
            // And nothing that decides nothing is left.
            #expect(MetaLog.notesToRemove(notes, known: known, now: day).isEmpty)
        }

        #expect(most <= MetaLog.compactAbove + 20, "Notes pile up: \(most)")
        // A month later with no changes: every note left still sets something for a photo in the library.
        let later = start.addingTimeInterval(400 * 86400)
        let leftover = Set(MetaLog.notesToRemove(notes, known: known, now: later).map(\.messageId))
        notes.removeAll { leftover.contains($0.messageId) }
        for note in notes { #expect(note.ids.contains { known.contains($0) }, "Note \(note.messageId) is only about deleted photos") }
        // About one note per album and value, plus favorites: the state, not the history.
        let fresh = MetaLog.compacted(notes, known: known)
        #expect(fresh.count <= 2 * (albums.count + 1), "State needs \(fresh.count) notes")
    }

    @Test(arguments: [1, 2, 3] as [UInt64])
    func recentlyDeletedNotesAreAllGoneAfterAYear(seed: UInt64) {
        var random = Random(state: seed)
        let start = Date(timeIntervalSince1970: 1_000 * 86400)
        var items: [String: MediaItem] = [:]
        for n in 0..<2_000 {
            items["i\(n)"] = MediaItem(id: "i\(n)", localIdentifier: nil, sha256: "h\(n)", filename: "IMG_\(n).HEIC", kind: .photo,
                                       creationDate: nil, fileSize: 1, status: .backedUp)
        }
        var notes: [TrashLog.Note] = []
        var messageId: Int64 = 0
        var most = 0

        func send(_ op: TrashLog.Op, _ ids: [String], on day: Date) {
            guard !ids.isEmpty else { return }
            messageId += 1
            notes.append(TrashLog.Note(messageId: messageId, date: day, op: op, ids: ids.sorted()))
        }

        for dayNumber in 0..<(365 + 40) {
            let day = start.addingTimeInterval(TimeInterval(dayNumber) * 86400)
            if dayNumber < 365 {
                let backedUp = items.values.filter { $0.status == .backedUp }.map(\.id)
                let deleted = (0..<random.next(15)).compactMap { _ in backedUp.randomElement(using: &random) }
                for id in deleted { items[id]?.status = .trashed; items[id]?.trashedAt = day }
                send(.delete, Array(Set(deleted)), on: day)
                let trashed = items.values.filter { $0.status == .trashed }.map(\.id)
                let recovered = Set((0..<random.next(4)).compactMap { _ in trashed.randomElement(using: &random) })
                for id in recovered { items[id]?.status = .backedUp; items[id]?.trashedAt = nil }
                send(.recover, Array(recovered), on: day)
            }
            // After 30 days in Recently Deleted, an item is deleted for good and leaves the index.
            for item in items.values where item.status == .trashed && day.timeIntervalSince(item.trashedAt!) > 30 * 86400 {
                items[item.id] = nil
            }
            let finished = Set(TrashLog.notesToRemove(notes, known: Array(items.values)).map(\.messageId))
            notes.removeAll { finished.contains($0.messageId) }
            most = max(most, notes.count)

            // Every item in Recently Deleted keeps the note that put it there; recovered ones aren't put back.
            let latest = TrashLog.latest(notes)
            for item in items.values {
                if item.status == .trashed { #expect(latest[item.id]?.op == .delete, "Day \(dayNumber): \(item.id) lost its note") }
                else { #expect(latest[item.id]?.op != .delete, "Day \(dayNumber): \(item.id) would go back to Recently Deleted") }
            }
        }
        #expect(most <= 2 * 31 + 5, "Notes pile up: \(most)")
        #expect(notes.isEmpty, "\(notes.count) Recently Deleted notes left after everything was done")
    }
}

extension Set {
    /// A seeded pick, so the year is the same every run.
    func randomElement(using random: inout NoteLifetimeTests.Random) -> Element? {
        isEmpty ? nil : sorted { "\($0)" < "\($1)" }[random.next(count)]
    }
}

extension Array {
    func randomElement(using random: inout NoteLifetimeTests.Random) -> Element? {
        isEmpty ? nil : self[random.next(count)]
    }
}
