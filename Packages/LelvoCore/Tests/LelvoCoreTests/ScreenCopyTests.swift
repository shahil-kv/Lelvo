import Foundation
import Testing
import LelvoCore
import ImageIO
import UniformTypeIdentifiers

@Suite struct ScreenCopyTests {
    func photo(_ name: String, bytes: Int64, kind: MediaKind = .photo) -> MediaItem {
        MediaItem(localIdentifier: nil, sha256: "h", filename: name, kind: kind, creationDate: Date(), fileSize: bytes, status: .backedUp)
    }

    @Test func bigAndRawPhotosGetOneNormalOnesDont() {
        #expect(ScreenCopyPolicy.shouldMake(photo("IMG_1.HEIC", bytes: 8 << 20)))
        #expect(ScreenCopyPolicy.shouldMake(photo("IMG_2.DNG", bytes: 1 << 20)))
        #expect(ScreenCopyPolicy.shouldMake(photo("IMG_3.HEIC", bytes: 5 << 20, kind: .livePhoto)))
        #expect(!ScreenCopyPolicy.shouldMake(photo("IMG_4.HEIC", bytes: 2 << 20)))
        #expect(!ScreenCopyPolicy.shouldMake(photo("IMG_5.MOV", bytes: 90 << 20, kind: .video)))
    }

    @Test func decidesOnTheFileTheViewerShows() {
        var edited = photo("IMG_6.HEIC", bytes: 2 << 20)
        edited.hasEdit = true
        edited.editedFilename = "FullSizeRender.jpg"
        edited.editedSize = 6 << 20
        #expect(ScreenCopyPolicy.shouldMake(edited))
    }

    @Test func notAgainOnceMadeOrSkipped() {
        var skipped = photo("IMG_7.DNG", bytes: 30 << 20)
        skipped.screenCopySkipped = true
        #expect(!ScreenCopyPolicy.shouldMake(skipped))
        var made = photo("IMG_8.DNG", bytes: 30 << 20)
        made.setParts([RemoteFile(messageId: 9, fileId: "f", fileUniqueId: "u", size: 400_000)], role: "d", expected: 1)
        #expect(made.hasScreenCopy)
        #expect(!ScreenCopyPolicy.shouldMake(made))
    }

    @Test func keptOnlyWhenMuchSmaller() {
        #expect(ScreenCopyPolicy.isWorthKeeping(copyBytes: 500_000, originalBytes: 30_000_000))
        #expect(!ScreenCopyPolicy.isWorthKeeping(copyBytes: 2_000_000, originalBytes: 3_000_000))
    }

    @Test func captionRoundTripsWithTheNewRole() throws {
        var meta = CaptionMeta(id: "0b7c0e3e-6f1e-4c55-9a33-1f3f0c0a9d10", role: .screenCopy, kind: .photo,
                               sha256: String(repeating: "a", count: 64), name: "IMG_1-screen.jpg", size: 420_000)
        meta.wh = [2048, 1536]
        meta.m = "image/jpeg"
        let caption = try CaptionCodec.encode(meta, captionKey: nil)
        #expect(caption.contains("\"r\":\"d\""))
        #expect(try CaptionCodec.decode(caption, captionKey: nil).r == .screenCopy)
    }

    func message(_ id: Int64, item: String, role: CaptionMeta.Role) -> CloudMessage {
        CloudMessage(messageId: id, meta: CaptionMeta(id: item, role: role, kind: .photo, sha256: String(repeating: "b", count: 64),
                                                      name: "IMG.DNG", size: 100), fileId: "f\(id)", uniqueId: "u\(id)", size: 100)
    }

    @Test func aPhotoIsCompleteWithoutItsScreenCopy() {
        let result = LibraryIndexer.build([message(1, item: "a", role: .original)])
        #expect(result.items.first?.status == .backedUp)
        let withCopy = LibraryIndexer.build([message(1, item: "a", role: .original), message(2, item: "a", role: .screenCopy)])
        #expect(withCopy.items.first?.status == .backedUp)
        #expect(withCopy.items.first?.hasScreenCopy == true)
    }

    /// An older version deleted the photo but not the screen copy it didn't know about.
    @Test func copiesWithoutAnOriginalAreLeftoversNotItems() {
        let result = LibraryIndexer.build([message(5, item: "gone", role: .screenCopy), message(6, item: "gone2", role: .smoothPreview),
                                           message(7, item: "kept", role: .original)])
        #expect(result.items.map(\.id) == ["kept"])
        #expect(result.orphanMessageIds == [5, 6])
    }
}

@Suite struct ScreenCopyEncoderTests {
    /// A 4032 × 3024 photo-sized image (noise, so it doesn't compress to nothing) written as PNG.
    func bigImage() throws -> URL {
        let w = 4032, h = 3024
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        var x: UInt32 = 12345
        for i in stride(from: 0, to: pixels.count, by: 4) {
            x = x &* 1664525 &+ 1013904223
            pixels[i] = UInt8(truncatingIfNeeded: x >> 24); pixels[i + 1] = UInt8(truncatingIfNeeded: x >> 16)
            pixels[i + 2] = UInt8(truncatingIfNeeded: x >> 8); pixels[i + 3] = 255
        }
        let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    @Test func makesASmallJPEGAtMost2048Pixels() throws {
        let source = try bigImage()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: out) }
        let copy = try ScreenCopyEncoder.encode(source, to: out)
        #expect(copy.width == 2048 && copy.height == 1536)
        let src = CGImageSourceCreateWithURL(out as CFURL, nil)!
        #expect(CGImageSourceGetType(src) as String? == UTType.jpeg.identifier)
        let original = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as! Int64
        let small = try FileManager.default.attributesOfItem(atPath: out.path)[.size] as! Int64
        #expect(ScreenCopyPolicy.isWorthKeeping(copyBytes: small, originalBytes: original))
    }

    @Test func refusesAFileThatIsntAnImage() throws {
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).dng")
        try Data("not an image".utf8).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        #expect(throws: ScreenCopyError.self) {
            try ScreenCopyEncoder.encode(junk, to: junk.appendingPathExtension("jpg"))
        }
    }
}
