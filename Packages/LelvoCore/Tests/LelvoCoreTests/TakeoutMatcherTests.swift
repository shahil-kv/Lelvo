import Testing
import Foundation
@testable import LelvoCore

@Suite struct TakeoutMatcherTests {
    func candidates(_ path: String) -> [String] { TakeoutMatcher.sidecarCandidates(forMediaPath: path) }

    @Test func plainAndSupplementalNames() {
        let c = candidates("Photos from 2019/IMG_1234.jpg")
        #expect(c.contains("Photos from 2019/IMG_1234.jpg.json"))
        #expect(c.contains("Photos from 2019/IMG_1234.jpg.supplemental-metadata.json"))
    }

    @Test func duplicateNumberMovesToTheEnd() {
        let c = candidates("Photos from 2019/IMG_1234(1).jpg")
        #expect(c.contains("Photos from 2019/IMG_1234.jpg(1).json"))
        #expect(c.contains("Photos from 2019/IMG_1234.jpg.supplemental-metadata(1).json"))
        #expect(c.contains("Photos from 2019/IMG_1234(1).jpg.json"))
    }

    @Test func longNamesAreCutTo51Characters() {
        let name = String(repeating: "a", count: 43) + ".jpg" // 47 characters
        let c = candidates("Photos from 2019/" + name)
        let cut = "Photos from 2019/" + String((name + ".supplemental-metadata").prefix(46)) + ".json"
        #expect(c.contains(cut))
        #expect(cut.split(separator: "/").last!.count == 51)
        let old = String(repeating: "b", count: 50) + ".jpg"
        #expect(candidates(old).contains(String(old.prefix(46)) + ".json"))
    }

    @Test func truncatedSupplementalVariants() {
        let c = candidates("IMG_1234.jpg")
        #expect(c.contains("IMG_1234.jpg.supplemental-met.json"))
        #expect(c.contains("IMG_1234.jpg.suppl.json"))
        #expect(c.contains("IMG_1234.jpg.s.json"))
    }

    @Test func editedCopiesShareTheOriginal() {
        #expect(TakeoutMatcher.originalPath(ofEditedPath: "Photos from 2019/IMG_1234-edited.jpg") == "Photos from 2019/IMG_1234.jpg")
        for suffix in ["-bearbeitet", "-modifié", "-editado", "-modificato"] {
            #expect(TakeoutMatcher.originalPath(ofEditedPath: "X/IMG_1\(suffix).HEIC") == "X/IMG_1.HEIC")
        }
        #expect(TakeoutMatcher.originalPath(ofEditedPath: "X/IMG_1.jpg") == nil)
        #expect(candidates("Photos from 2019/IMG_1234-edited.jpg").contains("Photos from 2019/IMG_1234.jpg.json"))
    }

    @Test func kinds() {
        #expect(TakeoutMatcher.kind(ofPath: "Photos from 2023/PXL_20231010_101010.MP") == .video)
        #expect(TakeoutMatcher.kind(ofPath: "Photos from 2023/PXL_20231010_101010.MP.jpg") == .photo)
        #expect(TakeoutMatcher.kind(ofPath: "Photos from 2019/IMG_1.HEIC") == .photo)
        #expect(TakeoutMatcher.kind(ofPath: "Photos from 2019/IMG_1.mov") == .video)
        #expect(TakeoutMatcher.kind(ofPath: "Photos from 2019/IMG_1.CR3") == .photo)
        #expect(TakeoutMatcher.kind(ofPath: "Goa 2019/metadata.json") == .albumMetadata)
        #expect(TakeoutMatcher.kind(ofPath: "Goa 2019/Metadaten.json") == .albumMetadata)
        #expect(TakeoutMatcher.kind(ofPath: "Goa 2019/métadonnées.json") == .albumMetadata)
        #expect(TakeoutMatcher.kind(ofPath: "Goa 2019/IMG_1.jpg.json") == .sidecar)
        #expect(TakeoutMatcher.kind(ofPath: "Drive/Notes/report.pdf") == .other)
        #expect(TakeoutMatcher.kind(ofPath: "Takeout/archive_browser.html") == .other)
    }

    @Test func normalizedKeysIgnoreCaseAndUnicodeForm() {
        #expect(TakeoutMatcher.normalized("A/Bild u\u{0308}.JPG") == TakeoutMatcher.normalized("a/bild ü.jpg"))
    }
}
