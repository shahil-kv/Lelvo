import Foundation
import Testing
import MemvoCore

@Suite struct LibraryIndexerTests {
    let id = "0b7c0e3e-6f1e-4c55-9a33-1f3f0c0a9d10"

    func msg(_ mid: Int64, role: CaptionMeta.Role = .original, kind: CaptionMeta.Kind = .photo, part: [Int64]? = nil, size: Int64 = 100) -> CloudMessage {
        var m = CaptionMeta(id: id, role: role, kind: kind, sha256: String(repeating: role == .original ? "a" : "b", count: 64),
                            name: role == .pairedVideo ? "IMG_1.MOV" : "IMG_1.HEIC", size: 1000)
        m.t = 1_700_000_000
        m.g = [1.5, 2.5]
        m.p = part
        return CloudMessage(messageId: mid, meta: m, fileId: "f\(mid)", uniqueId: "u\(mid)", size: size)
    }

    @Test func singlePhotoIsComplete() {
        let r = LibraryIndexer.build([msg(10)])
        #expect(r.items.count == 1)
        let item = r.items[0]
        #expect(item.status == .backedUp)
        #expect(item.parts("o").map(\.messageId) == [10])
        #expect(item.latitude == 1.5)
        #expect(item.creationDate == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(r.orphanMessageIds.isEmpty)
    }

    @Test func duplicatesKeepLowestMessageId() {
        let r = LibraryIndexer.build([msg(30), msg(10), msg(20)])
        #expect(r.items[0].parts("o").map(\.messageId) == [10])
        #expect(r.orphanMessageIds == [20, 30])
    }

    @Test func editedVersionIsRequiredWhenDeclared() {
        var om = msg(1).meta
        om.ed = 1
        let original = CloudMessage(messageId: 1, meta: om, fileId: "f1", uniqueId: "u1", size: 100)
        let missing = LibraryIndexer.build([original])
        #expect(missing.items[0].hasEdit == true)
        #expect(missing.items[0].status == .failed)

        var em = msg(2, role: .edited).meta
        em.n = "FullSizeRender.heic"
        em.s = 900
        let edited = CloudMessage(messageId: 2, meta: em, fileId: "f2", uniqueId: "u2", size: 100)
        let complete = LibraryIndexer.build([original, edited])
        #expect(complete.items[0].status == .backedUp)
        #expect(complete.items[0].editedFilename == "FullSizeRender.heic")
        #expect(complete.items[0].editedSize == 900)
        #expect(complete.items[0].parts("e").map(\.messageId) == [2])
    }

    @Test func uneditedItemNeedsNoEditedVersion() {
        let r = LibraryIndexer.build([msg(1)])
        #expect(r.items[0].hasEdit != true)
        #expect(r.items[0].status == .backedUp)
    }

    @Test func livePhotoNeedsPairedVideo() {
        let incomplete = LibraryIndexer.build([msg(1, kind: .live)])
        #expect(incomplete.items[0].status == .failed)
        let complete = LibraryIndexer.build([msg(1, kind: .live), msg(2, role: .pairedVideo, kind: .live)])
        #expect(complete.items[0].status == .backedUp)
        #expect(complete.items[0].kind == .livePhoto)
        #expect(complete.items[0].pairedVideoFilename == "IMG_1.MOV")
        #expect(complete.items[0].allMessageIds == [1, 2])
    }

    @Test func splitPartsMustAllBePresent() {
        let ps: Int64 = 1999 * 1_048_576
        let missing = LibraryIndexer.build([msg(1, kind: .video, part: [0, 3, ps]), msg(3, kind: .video, part: [2, 3, ps])])
        #expect(missing.items[0].status == .failed)
        let all = LibraryIndexer.build([msg(3, kind: .video, part: [2, 3, ps]), msg(1, kind: .video, part: [0, 3, ps]),
                                        msg(2, kind: .video, part: [1, 3, ps])])
        #expect(all.items[0].status == .backedUp)
        #expect(all.items[0].parts("o").map(\.messageId) == [1, 2, 3])
    }

    @Test func encryptedItemsRequireThumbnail() {
        var o = msg(1)
        var meta = o.meta
        meta.e = 1
        o = CloudMessage(messageId: 1, meta: meta, fileId: "f", uniqueId: "u", size: 1)
        #expect(LibraryIndexer.build([o]).items[0].status == .failed)
        var t = msg(2, role: .thumbnail).meta
        t.e = 1
        let r = LibraryIndexer.build([o, CloudMessage(messageId: 2, meta: t, fileId: "t", uniqueId: "t", size: 1)])
        #expect(r.items[0].status == .backedUp)
    }

    @Test func jobViewMapsStatus() {
        var item = LibraryIndexer.build([msg(1)]).items[0]
        #expect(item.job.state == .verified)
        item.job = JobMachine.reduce(JobStatus(), .start)
        #expect(item.status == .uploading)
    }
}
