import Foundation
import Testing
import MemvoCore

@Suite struct RestorePlanTests {
    func item(_ kind: MediaKind, roles: [String]) -> MediaItem {
        var m = MediaItem(localIdentifier: nil, sha256: "h", filename: "IMG_1.HEIC", kind: kind, creationDate: Date(), fileSize: 10, status: .backedUp)
        for (i, r) in roles.enumerated() {
            m.setParts([RemoteFile(messageId: Int64(i + 1), fileId: "f\(i)", fileUniqueId: "u\(i)", size: 10)], role: r, expected: 1)
        }
        return m
    }

    @Test func plainPhotoIsJustTheOriginal() {
        let plan = RestorePlan.make(for: item(.photo, roles: ["o"]))
        #expect(plan.downloads == ["o"])
        #expect(plan.edit == nil && plan.pairedVideo == nil && plan.rawAlternate == nil)
    }

    @Test func editedPhotoComesBackAsOriginalPlusRevertibleEdit() {
        var edited = item(.photo, roles: ["o", "e", "ad", "ad2"])
        edited.hasEdit = true
        let plan = RestorePlan.make(for: edited)
        #expect(plan.original == "o")
        #expect(plan.edit == RestorePlan.Edit(rendered: "e", adjustment: "ad", pairedVideo: nil))
        #expect(plan.downloads == ["o", "e", "ad"])
    }

    /// Backed up before adjustment data was stored: still the original with its edit applied (revertible to the original).
    @Test func olderEditedPhotoWithoutAdjustmentData() {
        var edited = item(.photo, roles: ["o", "e"])
        edited.hasEdit = true
        #expect(RestorePlan.make(for: edited).edit == RestorePlan.Edit(rendered: "e", adjustment: nil, pairedVideo: nil))
    }

    @Test func editedLivePhotoKeepsBothVideos() {
        var live = item(.livePhoto, roles: ["o", "pv", "e", "epv", "ad"])
        live.hasEdit = true
        let plan = RestorePlan.make(for: live)
        #expect(plan.pairedVideo == "pv")
        #expect(plan.edit?.pairedVideo == "epv")
        #expect(plan.downloads == ["o", "pv", "e", "ad", "epv"])
    }

    @Test func rawPlusJPEGKeepsTheRaw() {
        #expect(RestorePlan.make(for: item(.photo, roles: ["o", "ra"])).rawAlternate == "ra")
        #expect(RestorePlan.make(for: item(.video, roles: ["o", "ra"])).rawAlternate == nil)
    }

    @Test func favouriteHiddenAndAlbums() {
        var m = item(.photo, roles: ["o", "md"])
        m.favorite = true
        m.hidden = true
        m.albums = ["Trips", "Family"]
        let plan = RestorePlan.make(for: m)
        #expect(plan.favorite && plan.hidden)
        #expect(plan.albums == ["Trips", "Family"])
        #expect(plan.metadata == "md")
    }

    @Test func anEditFlagWithoutTheEditedFileRestoresTheOriginal() {
        var m = item(.photo, roles: ["o"])
        m.hasEdit = true
        #expect(RestorePlan.make(for: m).edit == nil)
    }
}

@Suite struct ExtraMetadataTests {
    @Test func albumsThatDontFitTheCaptionGoToMetadata() throws {
        var meta = CaptionMeta(id: "0b7c0e3e-6f1e-4c55-9a33-1f3f0c0a9d10", role: .original, kind: .photo,
                               sha256: String(repeating: "a", count: 64), name: "IMG_1.HEIC", size: 1)
        meta.a = ["Trips"]
        #expect(try CaptionCodec.keepsAlbums(meta))
        meta.a = (0..<80).map { "Album number \($0)" }
        #expect(try !CaptionCodec.keepsAlbums(meta))
        let extra = ExtraMetadata(a: meta.a)
        #expect(try ExtraMetadata.decode(extra.encoded()) == extra)
    }

    @Test func hiddenRoundTripsThroughTheCaptionAndIndex() throws {
        var meta = CaptionMeta(id: "0b7c0e3e-6f1e-4c55-9a33-1f3f0c0a9d10", role: .original, kind: .photo,
                               sha256: String(repeating: "a", count: 64), name: "IMG_1.HEIC", size: 1)
        meta.hid = 1
        let decoded = try CaptionCodec.decode(try CaptionCodec.encode(meta))
        #expect(decoded.hid == 1)
        let item = LibraryIndexer.build([CloudMessage(messageId: 1, meta: decoded, fileId: "f", uniqueId: "u", size: 1)]).items.first
        #expect(item?.hidden == true)
        #expect(item?.status == .backedUp)
    }

    /// New optional roles never make an item incomplete, and alone they're leftovers.
    @Test func newRolesAreOptional() {
        func msg(_ id: Int64, _ item: String, _ role: CaptionMeta.Role) -> CloudMessage {
            CloudMessage(messageId: id, meta: CaptionMeta(id: item, role: role, kind: .photo, sha256: String(repeating: "b", count: 64),
                                                          name: "x", size: 1), fileId: "f\(id)", uniqueId: "u\(id)", size: 1)
        }
        let result = LibraryIndexer.build([msg(1, "a", .original), msg(2, "a", .adjustment), msg(3, "a", .rawAlternate), msg(4, "a", .metadata)])
        #expect(result.items.first?.status == .backedUp)
        let leftovers = LibraryIndexer.build([msg(5, "b", .rawAlternate)])
        #expect(leftovers.items.isEmpty)
        #expect(leftovers.orphanMessageIds == [5])
    }
}
