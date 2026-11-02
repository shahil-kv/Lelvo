import Foundation
import Testing
import LelvoCore

@Suite struct SecondCopyTests {
    let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// 2024-05-10 in UTC.
    let may = Date(timeIntervalSince1970: 1_715_342_400)

    func item(_ id: String, _ name: String = "IMG_0001.HEIC", size: Int64 = 100, kind: MediaKind = .photo,
              date: Date? = nil, roles: [String] = ["o"]) -> MediaItem {
        var m = MediaItem(id: id, localIdentifier: nil, sha256: "h-\(id)", filename: name, kind: kind,
                          creationDate: date ?? may, fileSize: size, status: .backedUp)
        for (i, r) in roles.enumerated() {
            m.setParts([RemoteFile(messageId: Int64(i + 1), fileId: "f\(i)", fileUniqueId: "u\(i)", size: size)], role: r, expected: 1)
        }
        return m
    }

    func plan(_ items: [MediaItem], _ manifest: SecondCopy.Manifest = .init(), disk: [String: Int64] = [:]) -> SecondCopy.Plan {
        SecondCopy.plan(items: items, manifest: manifest, calendar: utc) { disk[$0] }
    }

    @Test func emptyFolderCopiesEverythingIntoYearAndMonth() {
        let p = plan([item("aaaaaaaa1")])
        #expect(p.toCopy.map(\.path) == ["2024/05/IMG_0001.HEIC"])
        #expect(p.toCopy.first?.role == "o")
        #expect(p.bytesToCopy == 100)
        #expect(p.upToDate == 0 && p.toAdopt.isEmpty)
    }

    @Test func livePhotoAndEditAddTheirOwnFiles() {
        var live = item("aaaaaaaa1", kind: .livePhoto, roles: ["o", "pv", "e"])
        live.pairedVideoSize = 40
        live.hasEdit = true
        live.editedFilename = "FullSizeRender.jpg"
        live.editedSize = 90
        let files = SecondCopy.wanted(live, calendar: utc)
        #expect(files.map(\.path) == ["2024/05/IMG_0001.HEIC", "2024/05/IMG_0001.MOV", "2024/05/IMG_0001 (edited).jpg"])
        #expect(files.map(\.size) == [100, 40, 90])
    }

    @Test func copiedFilesWithTheRightSizeAreNotCopiedAgain() {
        var m = SecondCopy.Manifest()
        m.files["aaaaaaaa1/o"] = .init(path: "2024/05/IMG_0001.HEIC", size: 100)
        let p = plan([item("aaaaaaaa1")], m, disk: ["2024/05/IMG_0001.HEIC": 100])
        #expect(p.toCopy.isEmpty)
        #expect(p.upToDate == 1 && p.upToDateBytes == 100)
    }

    /// A drive that was unplugged mid-copy, or a file deleted by hand: copied again, to the same place.
    @Test func missingOrTruncatedFilesAreCopiedAgainToTheSamePath() {
        var m = SecondCopy.Manifest()
        m.files["aaaaaaaa1/o"] = .init(path: "2024/05/IMG_0001-aaaaaa.HEIC", size: 100)
        m.files["bbbbbbbb2/o"] = .init(path: "2024/05/IMG_0002.HEIC", size: 100)
        let p = plan([item("aaaaaaaa1"), item("bbbbbbbb2", "IMG_0002.HEIC")], m, disk: ["2024/05/IMG_0002.HEIC": 37])
        #expect(p.toCopy.map(\.path) == ["2024/05/IMG_0001-aaaaaa.HEIC", "2024/05/IMG_0002.HEIC"])
    }

    /// Two different photos with the same name and size in one month: each gets its own file.
    @Test func sameNameAndSizeFromTwoItemsNeverShareAFile() {
        let p = plan([item("aaaaaaaa1"), item("bbbbbbbb2")])
        #expect(Set(p.toCopy.map(\.path)) == ["2024/05/IMG_0001.HEIC", "2024/05/IMG_0001-bbbbbb.HEIC"])
    }

    @Test func aPathOwnedByAnotherItemInTheManifestIsNotTaken() {
        var m = SecondCopy.Manifest()
        m.files["aaaaaaaa1/o"] = .init(path: "2024/05/img_0001.heic", size: 100)
        // aaaaaaaa1 is no longer in the library; its file stays, and the new item must not overwrite it.
        let p = plan([item("bbbbbbbb2")], m, disk: ["2024/05/img_0001.heic": 100])
        #expect(p.toCopy.map(\.path) == ["2024/05/IMG_0001-bbbbbb.HEIC"])
        #expect(p.removedFromLibrary == 1)
    }

    /// A folder used for Download a copy before: matching files are recorded, not downloaded again.
    @Test func filesAlreadyThereWithTheRightSizeAreAdopted() {
        let p = plan([item("aaaaaaaa1")], disk: ["2024/05/IMG_0001.HEIC": 100])
        #expect(p.toAdopt.map(\.path) == ["2024/05/IMG_0001.HEIC"])
        #expect(p.toCopy.isEmpty)
    }

    /// The user's own file with the same name but other contents is never overwritten.
    @Test func aDifferentFileAtThePathIsLeftAlone() {
        let p = plan([item("aaaaaaaa1")], disk: ["2024/05/IMG_0001.HEIC": 55])
        #expect(p.toCopy.map(\.path) == ["2024/05/IMG_0001-aaaaaa.HEIC"])
        #expect(p.toAdopt.isEmpty)
    }

    @Test func removedItemsAreCountedButNeverPlannedForDeletion() {
        var m = SecondCopy.Manifest()
        m.files["gone0001/o"] = .init(path: "2023/01/OLD.JPG", size: 10)
        m.files["gone0001/pv"] = .init(path: "2023/01/OLD.MOV", size: 10)
        let p = plan([], m)
        #expect(p.removedFromLibrary == 1)
        #expect(p.toCopy.isEmpty && p.toAdopt.isEmpty)
    }

    @Test func manifestRoundTripsAndRecords() throws {
        var m = SecondCopy.Manifest()
        let f = SecondCopy.File(itemId: "aaaaaaaa1", role: "pv", path: "2024/05/A.MOV", size: 0, date: nil)
        m.record(f, size: 42)
        let back = try JSONDecoder().decode(SecondCopy.Manifest.self, from: JSONEncoder().encode(m))
        #expect(back == m)
        #expect(back.files["aaaaaaaa1/pv"] == .init(path: "2024/05/A.MOV", size: 42))
        #expect(back.itemIds == ["aaaaaaaa1"])
    }

    @Test func namesAreSafeOnEveryDrive() {
        #expect(SecondCopy.sanitized("a/b:c?.jpg") == "a_b_c_.jpg")
        #expect(SecondCopy.sanitized(".hidden.jpg") == "_hidden.jpg")
        #expect(SecondCopy.sanitized("  ") == "file")
    }

    @Test func undatedItemsGoInto1970() {
        var undated = item("aaaaaaaa1")
        undated.creationDate = nil
        #expect(SecondCopy.wanted(undated, calendar: utc).first?.path == "1970/01/IMG_0001.HEIC")
    }
}
