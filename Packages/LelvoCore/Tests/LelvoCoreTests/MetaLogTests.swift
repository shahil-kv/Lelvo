import Testing
import Foundation
import CryptoKit
@testable import LelvoCore

@Suite struct MetaLogTests {
    let day0 = Date(timeIntervalSince1970: 100 * 86400)

    func item(albums: [String]? = nil, favorite: Bool? = nil) -> MediaItem {
        var item = MediaItem(localIdentifier: nil, sha256: "h", filename: "IMG_1.HEIC", kind: .photo, creationDate: nil, fileSize: 10, status: .backedUp)
        item.albums = albums
        item.favorite = favorite
        return item
    }

    func note(_ id: Int64, _ op: MetaLog.Op, _ ids: [String], album: String? = nil) -> MetaLog.Note {
        MetaLog.Note(messageId: id, date: day0, op: op, ids: ids, album: album)
    }

    // MARK: Format

    @Test func bodyAndCaptionRoundTrip() throws {
        let body = MetaLog.Body(op: .albumAdd, ids: ["a", "b"], album: "Goa Trip")
        let data = try MetaLog.encode(body)
        #expect(String(decoding: data, as: UTF8.self) == #"{"album":"Goa Trip","ids":["a","b"],"op":"album-add","v":1}"#)
        let caption = MetaLog.Caption(n: 2, h: IndexCodec.sha256Hex(data))
        let text = try MetaLog.caption(caption, captionKey: nil)
        #expect(text.hasPrefix("CGM1:"))
        #expect(MetaLog.isNote(text))
        #expect(MetaLog.parseCaption(text, captionKey: nil) == caption)
        #expect(MetaLog.read(data, caption: caption) == body)
        #expect(try MetaLog.encode(.init(op: .favorite, ids: ["a"])) == Data(#"{"ids":["a"],"op":"fav","v":1}"#.utf8))
    }

    @Test func encryptedCaptionNeedsTheKey() throws {
        let key = SymmetricKey(size: .bits256)
        let caption = MetaLog.Caption(n: 1, h: "aa")
        let text = try MetaLog.caption(caption, captionKey: key)
        #expect(text.hasPrefix("CGM1E:"))
        #expect(MetaLog.parseCaption(text, captionKey: key) == caption)
        #expect(MetaLog.parseCaption(text, captionKey: nil) == nil)
        // A Recently Deleted note's key label doesn't open it, and the other way round.
        #expect(TrashLog.parseCaption(text, captionKey: key) == nil)
    }

    /// Readers from before these notes skip them without downloading: not an item, not a snapshot, not a trash note.
    @Test func oldReadersIgnoreTheseNotes() throws {
        let plain = try MetaLog.caption(.init(n: 1, h: "aa"), captionKey: nil)
        #expect(!CaptionCodec.isLelvo(plain))
        #expect(!IndexSnapshot.isSnapshot(plain))
        #expect(!TrashLog.isNote(plain))
        #expect(!MetaLog.isNote(try TrashLog.caption(.init(n: 1, h: "aa"), captionKey: nil)))
    }

    /// The contract in docs/test-vectors/metalog1.json: changing the encoding breaks other readers.
    @Test func matchesTheCommittedVector() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/test-vectors/metalog1.json")
        let vector = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: String]
        let body = Data(vector["body"]!.utf8)
        #expect(try MetaLog.encode(MetaLog.Body(op: .albumAdd, ids: ["0b7c0e3e-6f1e-4c55-9a33-1f3f0c0a9d10"], album: "Goa Trip")) == body)
        let caption = MetaLog.Caption(n: 1, h: IndexCodec.sha256Hex(body))
        #expect(try MetaLog.caption(caption, captionKey: nil) == vector["plainCaption"])
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: unhex(vector["masterHex"]!)), salt: Data(repeating: 0, count: 32),
                                         info: Data("CloudGallery caption v1".utf8), outputByteCount: 32)
        #expect(MetaLog.parseCaption(vector["encryptedCaption"]!, captionKey: key) == caption)
    }

    @Test func damagedOrUnknownNotesAreIgnored() throws {
        let good = try MetaLog.encode(.init(op: .favorite, ids: ["a"]))
        #expect(MetaLog.read(good, caption: .init(n: 1, h: "wrong")) == nil)
        #expect(MetaLog.read(good, caption: .init(n: 2, h: IndexCodec.sha256Hex(good))) == nil)
        for json in [#"{"ids":["a"],"op":"explode","v":1}"#, #"{"ids":["a"],"op":"fav","v":2}"#,
                     #"{"ids":["a"],"op":"album-add","v":1}"#, #"{"album":"  ","ids":["a"],"op":"album-add","v":1}"#,
                     #"{"album":"X","ids":["a"],"op":"fav","v":1}"#] {
            let data = Data(json.utf8)
            #expect(MetaLog.read(data, caption: .init(n: 1, h: IndexCodec.sha256Hex(data))) == nil, "\(json)")
        }
        #expect(MetaLog.parseCaption("CGM1:not json", captionKey: nil) == nil)
    }

    // MARK: Which note wins

    @Test func newestNoteWinsForEachItemAndKey() {
        let notes = [note(10, .favorite, ["a", "b"]), note(12, .unfavorite, ["a"]), note(11, .albumAdd, ["a"], album: "Goa Trip")]
        let latest = MetaLog.latest(notes)
        #expect(latest["a"]?[.favorite]?.value == false)
        #expect(latest["b"]?[.favorite]?.value == true)
        #expect(latest["a"]?[.album("Goa Trip")]?.value == true)
        #expect(latest["b"]?[.album("Goa Trip")] == nil)
        // Order read doesn't matter: message ids decide.
        #expect(MetaLog.latest(notes.reversed())["a"]?[.favorite]?.value == false)
    }

    @Test func albumNamesIgnoreSurroundingSpaces() {
        let latest = MetaLog.latest([note(1, .albumAdd, ["a"], album: " Goa Trip "), note(2, .albumRemove, ["a"], album: "Goa Trip")])
        #expect(latest["a"]?[.album("Goa Trip")]?.value == false)
    }

    @Test func applySetsFavoriteAndAlbumsKeepingTheRest() {
        var it = item(albums: ["Family", "Goa Trip"], favorite: nil)
        #expect(MetaLog.apply([.favorite: true, .album("Goa Trip"): false, .album("Beach"): true], to: &it))
        #expect(it.favorite == true)
        #expect(it.albums == ["Family", "Beach"])
        #expect(!MetaLog.apply([.favorite: true, .album("Beach"): true], to: &it), "Applying again changes nothing")
        #expect(MetaLog.apply([.album("Family"): false, .album("Beach"): false], to: &it))
        #expect(it.albums == nil)
    }

    @Test func waitingChangesBeatNotes() {
        let latest = MetaLog.latest([note(5, .favorite, ["a"]), note(6, .albumAdd, ["a"], album: "X")])
        let values = MetaLog.values(for: "a", latest: latest, waiting: [.favorite: false])
        #expect(values[.favorite] == false)
        #expect(values[.album("X")] == true)
    }

    /// The Goa Trip case: 10 photos in the album, 2 of them favorites; whichever are saved carry both.
    @Test func goaTripAlbumAndFavoritesReachEachItem() {
        let ids = (0..<10).map { "p\($0)" }
        let latest = MetaLog.latest([note(1, .albumAdd, ids, album: "Goa Trip"), note(2, .favorite, ["p1", "p3"])])
        for (i, id) in ids.prefix(5).enumerated() {
            var it = item()
            MetaLog.apply(MetaLog.values(for: id, latest: latest, waiting: nil), to: &it)
            #expect(it.albums == ["Goa Trip"])
            #expect((it.favorite ?? false) == (i == 1 || i == 3))
        }
    }

    // MARK: Sending

    @Test func waitingChangesShareNotes() {
        var changes: [String: [MetaLog.Key: Bool]] = [:]
        for i in 0..<50 { changes["p\(i)", default: [:]][.favorite] = true }
        changes["p0", default: [:]][.album("Goa Trip")] = true
        changes["p1", default: [:]][.album("Goa Trip")] = true
        changes["p2", default: [:]][.favorite] = false
        let bodies = MetaLog.bodies(for: changes)
        #expect(bodies.count == 3, "50 favorites, one unfavorite and one album: three notes, not 52")
        #expect(bodies.contains(.init(op: .albumAdd, ids: ["p0", "p1"], album: "Goa Trip")))
        #expect(bodies.contains(.init(op: .unfavorite, ids: ["p2"])))
        #expect(bodies.first { $0.op == .favorite }?.ids.count == 49)
    }

    @Test func bigChangesAreSplit() {
        var changes: [String: [MetaLog.Key: Bool]] = [:]
        for i in 0..<(MetaLog.maxIdsPerNote + 1) { changes[String(format: "p%05d", i)] = [.favorite: true] }
        let bodies = MetaLog.bodies(for: changes)
        #expect(bodies.map(\.ids.count) == [MetaLog.maxIdsPerNote, 1])
    }

    // MARK: Cleaning up

    @Test func onlyNotesThatDecideNothingAreRemoved() {
        let old = note(1, .favorite, ["a", "b"])
        let newer = note(2, .unfavorite, ["a"])
        let album = note(3, .albumAdd, ["a"], album: "X")
        #expect(MetaLog.notesToRemove([old, newer, album]).isEmpty, "The old note still decides b")
        let both = note(4, .unfavorite, ["b"])
        #expect(MetaLog.notesToRemove([old, newer, album, both]) == [old])
        // A note for another key doesn't replace a favorite note.
        #expect(MetaLog.notesToRemove([note(1, .favorite, ["a"]), note(2, .albumAdd, ["a"], album: "X")]).isEmpty)
    }

    @Test func compactingKeepsTheStateAndFreesEveryOldNote() {
        let notes = [note(1, .favorite, ["a", "b"]), note(2, .unfavorite, ["a"]), note(3, .albumAdd, ["a", "c"], album: "X"),
                     note(4, .albumRemove, ["c"], album: "X")]
        let fresh = MetaLog.compacted(notes)
        var next: Int64 = 100
        let sent = fresh.map { body -> MetaLog.Note in next += 1; return note(next, body.op, body.ids, album: body.album) }
        let all = notes + sent
        #expect(Set(MetaLog.notesToRemove(all).map(\.messageId)) == [1, 2, 3, 4])
        let before = MetaLog.latest(notes).mapValues { $0.mapValues(\.value) }
        let after = MetaLog.latest(sent).mapValues { $0.mapValues(\.value) }
        #expect(before == after)
    }

    @Test func outboxKeysRoundTrip() {
        for key in [MetaLog.Key.favorite, .album("Goa Trip"), .album("a:b")] { #expect(MetaLog.Key(stored: key.stored) == key) }
        #expect(MetaLog.Key(stored: "a:") == nil)
        #expect(MetaLog.Key(stored: "x") == nil)
    }
}
