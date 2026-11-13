import Testing
import Foundation
@testable import LelvoCore

@Suite struct TakeoutSidecarTests {
    func sidecar(_ json: String) -> TakeoutSidecar? { TakeoutSidecar.parse(Data(json.utf8)) }

    let full = """
    {"title":"IMG_1234.jpg","description":"","imageViews":"12",
     "creationTime":{"timestamp":"1600000000","formatted":"13 Sep 2020"},
     "photoTakenTime":{"timestamp":"1562264521","formatted":"4 Jul 2019, 18:22:01 UTC"},
     "geoData":{"latitude":0.0,"longitude":0.0,"altitude":0.0,"latitudeSpan":0.0,"longitudeSpan":0.0},
     "geoDataExif":{"latitude":12.97,"longitude":77.59,"altitude":920.0,"latitudeSpan":0.0,"longitudeSpan":0.0},
     "people":[{"name":"Someone"}],"url":"https://photos.google.com/photo/x",
     "googlePhotosOrigin":{"mobileUpload":{"deviceType":"IOS_PHONE"}},"favorited":true}
    """

    @Test func parsesTakenTimeAsUTCSeconds() throws {
        let s = try #require(sidecar(full))
        #expect(s.takenAt == Date(timeIntervalSince1970: 1562264521))
        #expect(s.title == "IMG_1234.jpg")
    }

    @Test func zeroGeoIsNoPlace() throws {
        let s = try #require(sidecar("""
        {"title":"a.jpg","photoTakenTime":{"timestamp":"1"},
         "geoData":{"latitude":0.0,"longitude":0.0,"altitude":0.0},
         "geoDataExif":{"latitude":0.0,"longitude":0.0,"altitude":0.0}}
        """))
        #expect(s.latitude == nil)
        #expect(s.longitude == nil)
        #expect(s.altitude == nil)
    }

    @Test func fallsBackToGeoDataExif() throws {
        let s = try #require(sidecar(full))
        #expect(s.latitude == 12.97)
        #expect(s.longitude == 77.59)
        #expect(s.altitude == 920)
    }

    @Test func prefersGeoData() throws {
        let s = try #require(sidecar("""
        {"geoData":{"latitude":48.85,"longitude":2.35,"altitude":35.0},
         "geoDataExif":{"latitude":12.97,"longitude":77.59,"altitude":920.0}}
        """))
        #expect(s.latitude == 48.85)
        #expect(s.longitude == 2.35)
    }

    @Test func favorited() throws {
        #expect(try #require(sidecar(full)).favorite)
        #expect(try #require(sidecar(#"{"title":"a.jpg"}"#)).favorite == false)
    }

    @Test func numericTimestampAndMissingTime() throws {
        #expect(try #require(sidecar(#"{"photoTakenTime":{"timestamp":1562264521}}"#)).takenAt
                == Date(timeIntervalSince1970: 1562264521))
        #expect(try #require(sidecar(#"{"title":"a.jpg"}"#)).takenAt == nil)
        // Google writes 0 for "unknown" on some items.
        #expect(try #require(sidecar(#"{"photoTakenTime":{"timestamp":"0"}}"#)).takenAt == nil)
    }

    @Test func ignoresUnknownFields() {
        #expect(sidecar(full) != nil)
    }

    @Test func albumMetadataTitle() throws {
        let album = try #require(TakeoutAlbumMetadata.parse(Data("""
        {"title":"Goa 2019","description":"","access":"protected","date":{"timestamp":"1562264521","formatted":""}}
        """.utf8)))
        #expect(album.title == "Goa 2019")
        #expect(TakeoutAlbumMetadata.parse(Data(#"{"title":""}"#.utf8)) == nil)
    }

    @Test func garbageReturnsNil() {
        #expect(sidecar("not json") == nil)
        #expect(sidecar("[1,2]") == nil)
        #expect(TakeoutAlbumMetadata.parse(Data("not json".utf8)) == nil)
    }
}
