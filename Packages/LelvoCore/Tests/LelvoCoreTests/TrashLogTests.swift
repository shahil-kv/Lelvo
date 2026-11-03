import Testing
import Foundation
import CryptoKit
@testable import LelvoCore

@Suite struct TrashLogTests {
    let day0 = Date(timeIntervalSince1970: 100 * 86400)

    func item(_ status: ItemStatus = .backedUp, localId: String? = "A", hash: String = "h") -> MediaItem {
        var item = MediaItem(localIdentifier: localId, sha256: hash, filename: "IMG_1.HEIC", kind: .photo, creationDate: nil, fileSize: 10, status: status)
        item.setParts([RemoteFile(messageId: 1, fileId: "f", fileUniqueId: "u", size: 10)], role: "o", expected: 1)
        return item
    }

    func note(_ id: Int64, _ op: TrashLog.Op, _ ids: [String], day: Double = 0) -> TrashLog.Note {
        TrashLog.Note(messageId: id, date: day0.addingTimeInterval(day * 86400), op: op, ids: ids)
    }

    // MARK: Format

    @Test func bodyAndCaptionRoundTrip() throws {
        let body = TrashLog.Body(op: .delete, ids: ["a", "b"])
        let data = try TrashLog.encode(body)
        #expect(String(decoding: data, as: UTF8.self) == #"{"ids":["a","b"],"op":"del","v":1}"#)
        let caption = TrashLog.Caption(n: 2, h: IndexCodec.sha256Hex(data))
        let text = try TrashLog.caption(caption, captionKey: nil)
        #expect(text.hasPrefix("CGT1:"))
        #expect(TrashLog.isNote(text))
        #expect(TrashLog.parseCaption(text, captionKey: nil) == caption)
        #expect(TrashLog.read(data, caption: caption) == body)
    }

    @Test func encryptedCaptionNeedsTheKey() throws {
        let key = SymmetricKey(size: .bits256)
        let caption = TrashLog.Caption(n: 1, h: "aa")
        let text = try TrashLog.caption(caption, captionKey: key)
        #expect(text.hasPrefix("CGT1E:"))
        #expect(TrashLog.parseCaption(text, captionKey: key) == caption)
        #expect(TrashLog.parseCaption(text, captionKey: nil) == nil)
        #expect(TrashLog.parseCaption(text, captionKey: SymmetricKey(size: .bits256)) == nil)
    }

    @Test func oldReadersIgnoreNotes() throws {
        let plain = try TrashLog.caption(.init(n: 1, h: "aa"), captionKey: nil)
        #expect(!CaptionCodec.isLelvo(plain))
        #expect(!IndexSnapshot.isSnapshot(plain))
    }

    /// The contract in docs/test-vectors/trashlog1.json: changing the encoding breaks other readers.
    @Test func matchesTheCommittedVector() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/test-vectors/trashlog1.json")
        let vector = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: String]
        let body = Data(vector["body"]!.utf8)
        #expect(try TrashLog.encode(TrashLog.Body(op: .delete, ids: ["0b7c0e3e-6f1e-4c55-9a33-1f3f0c0a9d10"])) == body)
        let caption = TrashLog.Caption(n: 1, h: IndexCodec.sha256Hex(body))
        #expect(try TrashLog.caption(caption, captionKey: nil) == vector["plainCaption"])
        // Derived as docs/CLOUD_FORMAT.md §6.3 says, not through the app's code.
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: unhex(vector["masterHex"]!)), salt: Data(repeating: 0, count: 32),
                                         info: Data("CloudGallery caption v1".utf8), outputByteCount: 32)
        #expect(TrashLog.parseCaption(vector["encryptedCaption"]!, captionKey: key) == caption)
    }

    @Test func damagedOrUnknownNotesAreIgnored() throws {
        let good = try TrashLog.encode(.init(op: .delete, ids: ["a"]))
        #expect(TrashLog.read(good, caption: .init(n: 1, h: "wrong")) == nil)
        #expect(TrashLog.read(good, caption: .init(n: 2, h: IndexCodec.sha256Hex(good))) == nil)
        let unknown = Data(#"{"ids":["a"],"op":"explode","v":1}"#.utf8)
        #expect(TrashLog.read(unknown, caption: .init(n: 1, h: IndexCodec.sha256Hex(unknown))) == nil)
        let newer = Data(#"{"ids":["a"],"op":"del","v":2}"#.utf8)
        #expect(TrashLog.read(newer, caption: .init(n: 1, h: IndexCodec.sha256Hex(newer))) == nil)
        #expect(TrashLog.parseCaption("CGT1:not json", captionKey: nil) == nil)
    }

    // MARK: Which note wins

    @Test func newestNoteWinsForEachItem() {
        let notes = [note(5, .recover, ["a"]), note(3, .delete, ["a", "b"]), note(9, .delete, ["a"])]
        let latest = TrashLog.latest(notes)
        #expect(latest["a"]?.messageId == 9)
        #expect(latest["b"]?.messageId == 3)
    }

    @Test func deleteTrashesWithTheNotesDate() {
        var it = item()
        let n = note(1, .delete, [it.id], day: 2)
        let action = TrashLog.action(for: it, note: n, messagesSeen: false)
        #expect(action == .trash(n.date))
        TrashLog.apply(action, to: &it)
        #expect(it.status == .trashed)
        #expect(it.trashedAt == n.date)
    }

    @Test func aDifferentLocalDateTakesTheSharedDate() {
        var it = item()
        CloudTrash.trash(&it, now: day0)
        let n = note(1, .delete, [it.id], day: 1)
        #expect(TrashLog.action(for: it, note: n, messagesSeen: false) == .trash(n.date))
        it.trashedAt = n.date
        #expect(TrashLog.action(for: it, note: n, messagesSeen: false) == .none)
    }

    @Test func recoverBringsItBack() {
        var it = item()
        CloudTrash.trash(&it, now: day0)
        let action = TrashLog.action(for: it, note: note(2, .recover, [it.id]), messagesSeen: false)
        #expect(action == .recover)
        TrashLog.apply(action, to: &it)
        #expect(it.status == .backedUp)
        #expect(TrashLog.action(for: it, note: note(2, .recover, [it.id]), messagesSeen: false) == .none)
    }

    @Test func uploadsWaitForTheirNote() {
        for status in [ItemStatus.queued, .uploading, .failed] {
            let it = item(status)
            #expect(TrashLog.action(for: it, note: note(1, .delete, [it.id]), messagesSeen: false) == .none)
            #expect(TrashLog.action(for: it, note: note(1, .gone, [it.id]), messagesSeen: false) == .none)
        }
    }

    @Test func goneRemovesUnlessTheMessagesAreStillThere() {
        let it = item()
        let n = note(1, .gone, [it.id])
        #expect(TrashLog.action(for: it, note: n, messagesSeen: false) == .remove)
        #expect(TrashLog.action(for: it, note: n, messagesSeen: true) == .trash(n.date))
    }

    // MARK: Deleting for good

    @Test func purgeNeedsANoteAndNothingWaiting() {
        let it = item(.trashed)
        #expect(!TrashLog.mayPurge(it, latest: nil, waiting: []))
        #expect(!TrashLog.mayPurge(it, latest: note(1, .recover, [it.id]), waiting: []))
        #expect(!TrashLog.mayPurge(it, latest: note(1, .delete, [it.id]), waiting: [it.id]))
        #expect(TrashLog.mayPurge(it, latest: note(1, .delete, [it.id]), waiting: []))
    }

    @Test func aNoteGoesWhenAllItsPhotosAreDeleted() {
        let a = item(.trashed, localId: "A"), b = item(.trashed, localId: "B")
        let n = note(1, .delete, [a.id, b.id])
        #expect(TrashLog.notesToRemove([n], known: [a, b]).isEmpty)
        #expect(TrashLog.notesToRemove([n], known: [b]).isEmpty, "One photo is still waiting")
        #expect(TrashLog.notesToRemove([n], known: []) == [n])
    }

    @Test func recoveringEverythingLeavesNothing() {
        var a = item(.trashed, localId: "A")
        a.status = .backedUp
        let notes = [note(1, .delete, [a.id]), note(2, .recover, [a.id])]
        #expect(TrashLog.notesToRemove(notes, known: [a]).map(\.messageId) == [1, 2])
    }

    @Test func aRecoverNoteStaysWhileItsDeleteNoteDoes() {
        var a = item(.trashed, localId: "A")
        let b = item(.trashed, localId: "B")
        a.status = .backedUp
        let notes = [note(1, .delete, [a.id, b.id]), note(2, .recover, [a.id])]
        #expect(TrashLog.notesToRemove(notes, known: [a, b]).isEmpty, "An offline device must still see that a came back")
        #expect(TrashLog.notesToRemove(notes, known: [a]).map(\.messageId) == [1, 2], "b is deleted: both are finished")
    }

    @Test func deletingAgainFinishesTheOlderNotes() {
        let a = item(.trashed, localId: "A")
        let notes = [note(1, .delete, [a.id]), note(2, .recover, [a.id]), note(3, .delete, [a.id])]
        #expect(TrashLog.notesToRemove(notes, known: [a]).map(\.messageId) == [1, 2])
        #expect(TrashLog.notesToRemove(notes, known: []).map(\.messageId) == [1, 2, 3])
    }

    @Test func notesFromTestBuildsAreRemoved() {
        #expect(TrashLog.notesToRemove([note(1, .gone, ["a"])], known: [item()]).count == 1)
    }

    /// What happened on a device: the other one deleted the photos and their note while this one wasn't listening.
    @Test func aDeviceThatMissedTheDeleteAsksTelegram() {
        let a = item(.trashed, localId: "A"), b = item(.trashed, localId: "B")
        let n = note(1, .delete, [a.id, b.id])
        #expect(TrashLog.notesToConfirm(trashed: [a, b], notes: [n], waiting: []) == [1])
        #expect(TrashLog.uncovered(trashed: [a, b], notes: [n], stillInChannel: [1], waiting: []).isEmpty, "Its note is still there")
        #expect(TrashLog.uncovered(trashed: [a, b], notes: [n], stillInChannel: [], waiting: []).count == 2)
        #expect(TrashLog.uncovered(trashed: [a], notes: [], stillInChannel: [], waiting: [a.id]).isEmpty, "Its own change is waiting to be sent")
    }

    @Test func aRecoverNoteDoesNotKeepAnItemInRecentlyDeleted() {
        let a = item(.trashed, localId: "A")
        let notes = [note(1, .delete, [a.id]), note(2, .recover, [a.id])]
        #expect(TrashLog.uncovered(trashed: [a], notes: notes, stillInChannel: [1, 2], waiting: []).map(\.id) == [a.id])
    }

    @Test func trashedItemsWithoutANoteGetOne() {
        let a = item(.trashed, localId: "A"), b = item(.trashed, localId: "B"), c = item(.trashed, localId: "C")
        let notes = [note(1, .delete, [a.id])]
        let need = TrashLog.itemsNeedingANote(trashed: [a, b, c], notes: notes, waiting: [c.id])
        #expect(need.map(\.id) == [b.id])
    }

    // MARK: Pacing

    @Test func atMostOneNoteAMinute() {
        let now = day0
        #expect(TrashLog.sendDelay(lastSent: nil, now: now) == 5)
        #expect(TrashLog.sendDelay(lastSent: now.addingTimeInterval(-10), now: now) == 50)
        #expect(TrashLog.sendDelay(lastSent: now.addingTimeInterval(-300), now: now) == 5)
    }

    @Test func aFullScanRunsEveryWeek() {
        #expect(TrashLog.needsFullScan(lastFullScan: nil, now: day0))
        #expect(!TrashLog.needsFullScan(lastFullScan: day0.addingTimeInterval(-6 * 86400), now: day0))
        #expect(TrashLog.needsFullScan(lastFullScan: day0.addingTimeInterval(-8 * 86400), now: day0))
    }

    // MARK: Store

    @Test func aDeleteAndItsNoteAreRecordedTogether() throws {
        let store = try LibraryStore(url: nil)
        let photo = item()
        try store.upsert(photo)
        let moved = try store.changeTrashState(id: photo.id, op: .delete, chatId: 1) { CloudTrash.trash(&$0, now: day0) }
        #expect(moved?.status == .trashed)
        #expect(try store.queuedTrashChanges(chatId: 1)[.delete] == [photo.id])
        try store.clearTrashChanges(.delete, itemIds: [photo.id])

        let back = try store.changeTrashState(id: photo.id, op: .recover, chatId: 1) { CloudTrash.recover(&$0) }
        #expect(back?.status == .backedUp)
        #expect(try store.queuedTrashChanges(chatId: 1)[.recover] == [photo.id])
    }

    @Test func nothingIsQueuedWhenTheStateDidNotChange() throws {
        let store = try LibraryStore(url: nil)
        var uploading = item(.uploading)
        uploading.localIdentifier = "A"
        try store.upsert(uploading)
        let same = try store.changeTrashState(id: uploading.id, op: .delete, chatId: 1) { CloudTrash.trash(&$0, now: day0) }
        #expect(same?.status == .uploading)
        #expect(try store.queuedTrashChanges(chatId: 1).isEmpty)
        let missing = try store.changeTrashState(id: "missing", op: .delete, chatId: 1) { CloudTrash.trash(&$0, now: day0) }
        #expect(missing == nil)
    }

    @Test func noLibraryChangesTheItemWithoutANote() throws {
        let store = try LibraryStore(url: nil)
        let photo = item()
        try store.upsert(photo)
        let moved = try store.changeTrashState(id: photo.id, op: .delete, chatId: nil) { CloudTrash.trash(&$0, now: day0) }
        #expect(moved?.status == .trashed)
        #expect(try store.queuedTrashChanges(chatId: 1).isEmpty)
    }

    @Test func anItemIsGoneOnlyWhenEveryMessageIs() {
        var photo = item()
        photo.setParts([RemoteFile(messageId: 2, fileId: "g", fileUniqueId: "v", size: 10)], role: "pv", expected: 1)
        #expect(!TrashLog.allMessagesGone(photo, existing: [1, 2]))
        #expect(!TrashLog.allMessagesGone(photo, existing: [2]), "The first message going leaves the rest to keep")
        #expect(TrashLog.allMessagesGone(photo, existing: []))
        var empty = item()
        empty.cloudParts = nil
        #expect(!TrashLog.allMessagesGone(empty, existing: []), "No messages known says nothing about Telegram")
    }

    @Test func aNoteWaitsForAFreeUploadAndGoesNext() {
        var slots = UploadSlots(limit: 2)
        var got = slots.acquireForLane()
        #expect(got)
        got = slots.acquireForLane()
        #expect(got)
        got = slots.acquireForLane()
        #expect(!got, "Never more than two")
        got = slots.acquireForNote()
        #expect(!got, "A note isn't a third upload")
        slots.release()
        got = slots.acquireForLane()
        #expect(!got, "The waiting note goes before the next photo")
        got = slots.acquireForNote()
        #expect(got)
        got = slots.acquireForLane()
        #expect(!got)
        slots.release()
        got = slots.acquireForLane()
        #expect(got)
    }

    @Test func aNoteThatGivesUpDoesNotHoldTheBackup() {
        var slots = UploadSlots(limit: 1)
        var got = slots.acquireForLane()
        #expect(got)
        got = slots.acquireForNote()
        #expect(!got)
        slots.release()
        slots.stopWaitingForNote()
        got = slots.acquireForLane()
        #expect(got)
    }

    @Test func retiredChangesLeaveTheQueue() throws {
        let store = try LibraryStore(url: nil)
        try store.queueTrashChange(.gone, itemIds: ["a"], chatId: 1)
        try store.queueTrashChange(.delete, itemIds: ["b"], chatId: 1)
        try store.dropRetiredTrashChanges()
        let queued = try store.queuedTrashChanges(chatId: 1)
        #expect(queued[.gone] == nil)
        #expect(queued[.delete] == ["b"])
    }

    @Test func storeKeepsNotesOutboxAndOffBackup() throws {
        let store = try LibraryStore(url: nil)
        let n = note(7, .delete, ["a", "b"], day: 1)
        try store.addTrashNote(n)
        #expect(try store.trashNotes() == [n])
        try store.removeTrashNotes(messageIds: [7])
        #expect(try store.trashNotes().isEmpty)

        try store.queueTrashChange(.delete, itemIds: ["a", "b"], chatId: 1)
        try store.queueTrashChange(.recover, itemIds: ["a"], chatId: 1)
        try store.queueTrashChange(.delete, itemIds: ["c"], chatId: 2)
        let queued = try store.queuedTrashChanges(chatId: 1)
        #expect(queued[.recover] == ["a"])
        #expect(queued[.delete] == ["b"])
        try store.clearTrashChanges(.delete, itemIds: ["a", "b"])
        #expect(try store.queuedTrashChanges(chatId: 1)[.recover] == ["a"], "A change made during the send stays")
        #expect(try store.queuedTrashChanges(chatId: 1)[.delete] == nil)
        #expect(try store.queuedTrashChanges(chatId: 2)[.delete] == ["c"])
    }

    @Test func forgettingKeepsThePhotoOffBackup() throws {
        let store = try LibraryStore(url: nil)
        let it = item(.trashed, localId: "A", hash: "abc")
        try store.upsert(it)
        try store.addAlias(localIdentifier: "A2", itemId: it.id)
        try store.forgetDeletedItem(it)
        #expect(try store.item(id: it.id) == nil)
        #expect(try store.offBackupLocalIdentifiers() == ["A", "A2"])
        #expect(try store.isOffBackup(sha256: "abc"))
        #expect(try !store.isOffBackup(sha256: "other"))
        try store.allowBackup(localIdentifier: "A")
        #expect(try store.offBackupLocalIdentifiers() == ["A2"])
    }

    @Test func aDifferentEditOfADeletedPhotoIsStillBackedUp() throws {
        let store = try LibraryStore(url: nil)
        var edited = item(.trashed, localId: "A", hash: "abc")
        edited.roleHashes = ["e": "edit1"]
        try store.upsert(edited)
        try store.forgetDeletedItem(edited)
        #expect(try store.isOffBackup(sha256: "abc", editHash: "edit1"))
        #expect(try !store.isOffBackup(sha256: "abc", editHash: "edit2"), "Its own photo")
        #expect(try store.isOffBackup(sha256: "abc"), "An unedited copy matches, as a duplicate does")
        #expect(try !store.isOffBackup(sha256: "ab"), "The whole hash has to match")
    }

    @Test func aPlainDeletedPhotoDoesNotHideAnEditedCopy() throws {
        let store = try LibraryStore(url: nil)
        let plain = item(.trashed, localId: "A", hash: "abc")
        try store.upsert(plain)
        try store.forgetDeletedItem(plain)
        #expect(try store.isOffBackup(sha256: "abc"))
        #expect(try !store.isOffBackup(sha256: "abc", editHash: "edit1"))
    }

    @Test func offBackupKeysCanBeKeptAcrossAWipe() throws {
        let store = try LibraryStore(url: nil)
        var edited = item(.trashed, localId: "A", hash: "abc")
        edited.roleHashes = ["e": "edit1"]
        try store.upsert(edited)
        try store.forgetDeletedItem(edited)
        let keys = try store.offBackupKeys()
        try store.deleteAll()
        #expect(try store.offBackupKeys().isEmpty)
        try store.restoreOffBackupKeys(keys)
        #expect(try store.offBackupLocalIdentifiers() == ["A"])
        #expect(try store.isOffBackup(sha256: "abc", editHash: "edit1"))
    }

    @Test func resettingClearsEverything() throws {
        let store = try LibraryStore(url: nil)
        try store.addTrashNote(note(1, .delete, ["a"]))
        try store.queueTrashChange(.delete, itemIds: ["a"], chatId: 1)
        try store.keepOffBackup(localIdentifier: "A")
        try store.deleteAll()
        #expect(try store.trashNotes().isEmpty)
        #expect(try store.queuedTrashChanges(chatId: 1).isEmpty)
        #expect(try store.offBackupLocalIdentifiers().isEmpty)
    }
}
