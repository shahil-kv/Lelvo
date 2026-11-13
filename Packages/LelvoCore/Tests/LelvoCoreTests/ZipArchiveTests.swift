import Testing
import Foundation
import CryptoKit
@testable import LelvoCore

@Suite struct ZipArchiveTests {
    func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test func crc32KnownValue() {
        var crc = CRC32()
        crc.update(Data("123456789".utf8))
        #expect(crc.value == 0xCBF4_3926)
    }

    @Test func listsStoredAndDeflatedEntries() throws {
        let url = try ZipFixture.write([
            .init("a.jpg", Data(repeating: 7, count: 1000)),
            .init("b.json", #"{"title":"a.jpg"}"#, deflate: true)
        ])
        let zip = try ZipArchive(url: url)
        #expect(zip.entries.map(\.path) == ["a.jpg", "b.json"])
        #expect(zip.entries[0].size == 1000)
        #expect(zip.entries[0].method == 0)
        #expect(zip.entries[1].size == 17)
        #expect(zip.entries[1].method == 8)
        #expect(String(decoding: try zip.data(zip.entries[1], limit: 1 << 20), as: UTF8.self) == #"{"title":"a.jpg"}"#)
    }

    @Test func extractsBitForBitAndReturnsSHA256() throws {
        let input = ZipFixture.random(3 << 20) + Data(repeating: 42, count: 1 << 20)
        let zip = try ZipArchive(url: try ZipFixture.write([.init("Photos from 2019/IMG_1.MOV", input, deflate: true)]))
        let dst = tempFile()
        var reported: Int64 = 0
        let hash = try zip.extract(zip.entries[0], to: dst) { reported = $0 }
        #expect(try Data(contentsOf: dst) == input)
        #expect(hash == sha256Hex(input))
        #expect(reported == Int64(input.count))
    }

    @Test func readsZip64() throws {
        let input = ZipFixture.random(70_000)
        let zip = try ZipArchive(url: try ZipFixture.write([.init("a.jpg", input), .init("b.jpg", input, deflate: true)],
                                                          zip64: true))
        #expect(zip.entries.count == 2)
        #expect(zip.entries[1].size == Int64(input.count))
        let dst = tempFile()
        _ = try zip.extract(zip.entries[1], to: dst)
        #expect(try Data(contentsOf: dst) == input)
    }

    @Test func dataDescriptorEntries() throws {
        let input = Data("hello takeout".utf8)
        let zip = try ZipArchive(url: try ZipFixture.write([
            .init("a.json", input, deflate: true, descriptor: true),
            .init("b.jpg", input, descriptor: true)
        ]))
        #expect(zip.entries.map(\.size) == [13, 13])
        #expect(try zip.data(zip.entries[0], limit: 100) == input)
        #expect(try zip.data(zip.entries[1], limit: 100) == input)
    }

    @Test func crcMismatchThrows() throws {
        var bytes = ZipFixture.make([.init("a.jpg", Data(repeating: 1, count: 100))])
        bytes[30 + 5 + 10] ^= 0xFF // a byte inside the entry's data, after the 30-byte header and "a.jpg"
        let url = tempFile()
        try bytes.write(to: url)
        let zip = try ZipArchive(url: url)
        let dst = tempFile()
        #expect(throws: ZipError.crcMismatch("a.jpg")) { try zip.extract(zip.entries[0], to: dst) }
        #expect(!FileManager.default.fileExists(atPath: dst.path))
    }

    @Test func refusesLargeDataReads() throws {
        let zip = try ZipArchive(url: try ZipFixture.write([.init("a.json", Data(repeating: 1, count: 100))]))
        #expect(throws: ZipError.tooLarge("a.json")) { try zip.data(zip.entries[0], limit: 50) }
    }

    @Test func tgzIsRecognised() throws {
        let url = tempFile()
        try (Data([0x1F, 0x8B, 0x08, 0x00]) + ZipFixture.random(100)).write(to: url)
        #expect(throws: ZipError.tgz) { try ZipArchive(url: url) }
    }

    @Test func notAZip() throws {
        let url = tempFile()
        try ZipFixture.random(5000).write(to: url)
        #expect(throws: ZipError.notAZip) { try ZipArchive(url: url) }
    }

    @Test func utf8Names() throws {
        let name = "Takeout/Google Fotos/Fotos von 2019/Bild ü.jpg"
        let zip = try ZipArchive(url: try ZipFixture.write([.init(name, "x")]))
        #expect(zip.entries.map(\.path) == [name])
    }

    @Test func directoriesAreNotEntries() throws {
        let zip = try ZipArchive(url: try ZipFixture.write([.init("Takeout/", Data()), .init("Takeout/a.jpg", "x")]))
        #expect(zip.entries.map(\.path) == ["Takeout/a.jpg"])
    }

    @Test func modifiedDateFromDOSTime() throws {
        let zip = try ZipArchive(url: try ZipFixture.write([.init("a.jpg", "x")]))
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: try #require(zip.entries[0].modified))
        #expect(parts.year == 2019 && parts.month == 7 && parts.day == 4)
    }
}
