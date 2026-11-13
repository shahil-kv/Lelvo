import Testing
import Foundation
@testable import LelvoCore

@Suite struct TakeoutPlannerTests {
    let root = "Takeout/Google Photos/"

    func entry(_ path: String, source: String = "A", size: Int64 = 100, crc: UInt32 = 1) -> TakeoutSourceEntry {
        TakeoutSourceEntry(sourceId: source, entry: ZipEntry(path: root + path, compressedSize: size, size: size, crc32: crc,
                                                            method: 0, localHeaderOffset: 0, modified: nil))
    }

    func taken(_ seconds: TimeInterval, favorite: Bool = false) -> TakeoutSidecar {
        TakeoutSidecar(takenAt: Date(timeIntervalSince1970: seconds), favorite: favorite)
    }

    func planned(_ source: TakeoutSourceEntry, kind: MediaKind = .photo) -> TakeoutPlannedItem {
        TakeoutPlannedItem(key: TakeoutPlanner.key(for: source.entry), kind: kind, primary: source,
                           pairedVideo: nil, edited: nil, copies: [], albums: [], sidecar: nil, dateSource: .fileWillTell)
    }

    func plan(_ entries: [TakeoutSourceEntry], sidecars: [String: TakeoutSidecar] = [:], albums: [String: String] = [:],
              allFilesAdded: Bool = false, imported: Set<String> = []) -> TakeoutPlan {
        TakeoutPlanner.plan(entries: entries,
                            sidecars: Dictionary(uniqueKeysWithValues: sidecars.map { (root + $0.key, $0.value) }),
                            albumTitles: Dictionary(uniqueKeysWithValues: albums.map { (root + $0.key, $0.value) }),
                            allFilesAdded: allFilesAdded, alreadyImportedKeys: imported)
    }

    @Test func yearAndAlbumCopiesBecomeOneItemWithAlbums() {
        let p = plan([entry("Photos from 2019/IMG_1.jpg"), entry("Goa 2019/IMG_1.jpg", source: "B")],
                     sidecars: ["Photos from 2019/IMG_1.jpg.json": taken(1)],
                     albums: ["Goa 2019": "Goa 2019", "Photos from 2019": "Photos from 2019"])
        #expect(p.items.count == 1)
        #expect(p.items[0].albums == ["Goa 2019"])
        #expect(p.items[0].primary.entry.path == root + "Photos from 2019/IMG_1.jpg")
        #expect(p.items[0].copies.map(\.sourceId) == ["B"])
        #expect(p.entryKeys.count == 2)
        #expect(Set(p.entryKeys.values) == [p.items[0].key])
    }

    @Test func sameNameDifferentContentStaysTwoItems() {
        let p = plan([entry("Photos from 2019/IMG_1.jpg", crc: 1), entry("Photos from 2020/IMG_1.jpg", crc: 2)])
        #expect(p.items.count == 2)
    }

    @Test func livePhotoPairsHEICAndMOV() {
        let p = plan([entry("Photos from 2019/IMG_1.HEIC"), entry("Photos from 2019/IMG_1.MOV", size: 900, crc: 9)])
        #expect(p.items.count == 1)
        #expect(p.items[0].kind == .livePhoto)
        #expect(p.items[0].pairedVideo?.entry.path == root + "Photos from 2019/IMG_1.MOV")
        #expect(p.photoCount == 1 && p.videoCount == 0)
    }

    @Test func movWithoutStillStaysVideo() {
        let p = plan([entry("Photos from 2019/IMG_2.MOV")])
        #expect(p.items.map(\.kind) == [.video])
        #expect(p.videoCount == 1)
    }

    @Test func editedBecomesEditOfOriginal() {
        let p = plan([entry("Photos from 2019/IMG_3.jpg"), entry("Photos from 2019/IMG_3-edited.jpg", crc: 3)],
                     sidecars: ["Photos from 2019/IMG_3.jpg.json": taken(5)])
        #expect(p.items.count == 1)
        #expect(p.items[0].edited?.entry.path == root + "Photos from 2019/IMG_3-edited.jpg")
        #expect(p.items[0].dateSource == .google)
    }

    @Test func editedWithoutOriginalIsItsOwnPhotoWithTheOriginalsSidecar() {
        let p = plan([entry("Photos from 2019/IMG_3-edited.jpg")], sidecars: ["Photos from 2019/IMG_3.jpg.json": taken(5)])
        #expect(p.items.count == 1)
        #expect(p.items[0].edited == nil)
        #expect(p.items[0].sidecar?.takenAt == Date(timeIntervalSince1970: 5))
    }

    @Test func sidecarFromAnotherZipIsUsed() {
        let p = plan([entry("Photos from 2019/IMG_4.png", source: "A")],
                     sidecars: ["Photos from 2019/IMG_4.png.supplemental-metadata.json": taken(7, favorite: true)])
        #expect(p.items[0].dateSource == .google)
        #expect(p.items[0].sidecar?.favorite == true)
    }

    @Test func sidecarFoundByTitleWhenTheNameWasCut() {
        var sidecar = taken(8)
        sidecar.title = "a very long original name that google cut short.jpg"
        let p = plan([entry("Photos from 2019/a very long original name that google cut sh.jpg")],
                     sidecars: ["Photos from 2019/a very long original name that google c.json": sidecar])
        #expect(p.items[0].dateSource == .google)
    }

    @Test func pngWithoutSidecarWaitsUntilAllFilesAdded() {
        #expect(plan([entry("Photos from 2019/Screenshot.png")]).items[0].dateSource == .waiting)
        #expect(plan([entry("Photos from 2019/Screenshot.png")], allFilesAdded: true).items[0].dateSource == .fileWillTell)
    }

    @Test func heicWithoutSidecarLetsTheFileTell() {
        #expect(plan([entry("Photos from 2019/IMG_5.HEIC")]).items[0].dateSource == .fileWillTell)
        #expect(plan([entry("Photos from 2019/VID_5.mp4")]).items[0].dateSource == .fileWillTell)
    }

    @Test func nonMediaIsSkippedAndCounted() {
        let p = plan([entry("Photos from 2019/IMG_6.jpg"), entry("Drive/report.pdf"),
                      entry("Photos from 2019/IMG_6.jpg.json", crc: 7)])
        #expect(p.items.count == 1)
        #expect(p.skipped.map(\.entry.path) == [root + "Drive/report.pdf"])
    }

    @Test func itemKeyIsStableAcrossRuns() {
        let a = [entry("Photos from 2019/IMG_7.jpg", crc: 7), entry("Goa 2019/IMG_7.jpg", crc: 7),
                 entry("Photos from 2019/IMG_8.jpg", crc: 8)]
        #expect(Set(plan(a).items.map(\.key)) == Set(plan(a.reversed()).items.map(\.key)))
    }

    @Test func duplicateNumberIsIgnoredWhenGroupingCopies() {
        let p = plan([entry("Photos from 2019/IMG_1(1).jpg"), entry("Goa 2019/IMG_1.jpg")], albums: ["Goa 2019": "Goa"])
        #expect(p.items.count == 1)
        #expect(p.items[0].albums == ["Goa"])
    }

    @Test func pixelMotionPairStaysTwoItems() {
        let p = plan([entry("Photos from 2023/PXL_1.MP.jpg"), entry("Photos from 2023/PXL_1.MP.mp4", crc: 2)])
        #expect(p.items.count == 2)
        #expect(p.items.allSatisfy { $0.pairedVideo == nil })
        #expect(Set(p.items.map(\.kind)) == [.photo, .video])
    }

    @Test func lateAlbumCopyOfImportedItem() throws {
        let copy = entry("Goa 2019/IMG_9.jpg", source: "B")
        let key = TakeoutPlanner.key(for: copy.entry)
        let p = plan([copy], sidecars: ["Goa 2019/IMG_9.jpg.json": taken(1, favorite: true)],
                     albums: ["Goa 2019": "Goa 2019"], imported: [key])
        #expect(p.items.isEmpty)
        #expect(p.lateDetails == [TakeoutLateDetail(key: key, albums: ["Goa 2019"], favorite: true)])
        #expect(p.entryKeys[copy] == key)
    }

    @Test func livePhotoHalfInAnotherSourceIsSeparate() {
        let still = entry("Photos from 2019/IMG_10.HEIC", source: "A")
        let movie = entry("Photos from 2019/IMG_10.MOV", source: "B", crc: 10)
        let p = plan([still, movie], imported: [TakeoutPlanner.key(for: still.entry)])
        #expect(p.items.map(\.kind) == [.video])
        #expect(p.items[0].primary == movie)
        let separate = TakeoutPlanner.importedSeparately(p.items, alreadyImported: [planned(still)])
        #expect(separate.map(\.entry.path) == [movie.entry.path])
    }

    @Test func editedCopyImportedSeparatelyWhenTheOriginalIsAlreadyIn() {
        let original = entry("Photos from 2019/IMG_3.jpg")
        let edited = entry("Photos from 2019/IMG_3-edited.jpg", source: "B", crc: 3)
        let p = plan([original, edited], imported: [TakeoutPlanner.key(for: original.entry)])
        let separate = TakeoutPlanner.importedSeparately(p.items, alreadyImported: [planned(original)])
        #expect(separate.map(\.entry.path) == [edited.entry.path])
    }

    @Test func pairedLivePhotoAndOrdinaryVideoAreNotSeparate() {
        let still = entry("Photos from 2019/IMG_1.HEIC")
        let movie = entry("Photos from 2019/IMG_1.MOV", crc: 9)
        let alone = entry("Photos from 2019/IMG_2.MOV", crc: 2)
        let paired = plan([still, movie])
        #expect(TakeoutPlanner.importedSeparately(paired.items, alreadyImported: []).isEmpty)
        let video = plan([alone])
        #expect(TakeoutPlanner.importedSeparately(video.items, alreadyImported: []).isEmpty)
        let editedOnly = plan([entry("Photos from 2019/IMG_3-edited.jpg")])
        #expect(TakeoutPlanner.importedSeparately(editedOnly.items, alreadyImported: []).isEmpty)
    }

    @Test func attachedEditIsNotListedAsSeparate() {
        let original = entry("Photos from 2019/IMG_3.jpg")
        let edited = entry("Photos from 2019/IMG_3-edited.jpg", crc: 3)
        var item = planned(original)
        item.edited = edited
        #expect(TakeoutPlanner.importedSeparately([item], alreadyImported: [item]).isEmpty)
    }

    @Test func yearFoldersWithMetadataAreNotAlbums() {
        let p = plan([entry("Fotos von 2019/IMG_1.jpg")], albums: ["Fotos von 2019": "Fotos von 2019"])
        #expect(p.items[0].albums.isEmpty)
    }
}
