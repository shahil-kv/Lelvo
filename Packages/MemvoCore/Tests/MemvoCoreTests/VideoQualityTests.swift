import Foundation
import Testing
import MemvoCore

@Suite struct VideoQualityTests {
    func video(mb: Int64, seconds: Double, w: Int = 3840, h: Int = 2160) -> MediaItem {
        MediaItem(localIdentifier: "A", sha256: "h", filename: "IMG_1.MOV", kind: .video, creationDate: nil,
                  pixelWidth: w, pixelHeight: h, duration: seconds, fileSize: mb << 20, status: .backedUp)
    }

    @Test func copiesVideosTelegramCantStream() {
        #expect(StreamingCopyPolicy.shouldMake(video(mb: 400, seconds: 60)))                     // 4K, ~56 Mbit/s
        #expect(StreamingCopyPolicy.shouldMake(video(mb: 28, seconds: 8)))                       // short 4K clip, ~29 Mbit/s
        #expect(StreamingCopyPolicy.shouldMake(video(mb: 60, seconds: 60, w: 1920, h: 1080)))   // 1080p, ~8 Mbit/s
    }

    @Test func skipsSmallLowBitrateAndNonVideos() {
        #expect(!StreamingCopyPolicy.shouldMake(video(mb: 3, seconds: 2)))                       // under 4 MB
        #expect(!StreamingCopyPolicy.shouldMake(video(mb: 20, seconds: 60, w: 1920, h: 1080)))  // ~2.8 Mbit/s already
        var live = video(mb: 400, seconds: 60)
        live.kind = .livePhoto
        #expect(!StreamingCopyPolicy.shouldMake(live))
        var noDuration = video(mb: 400, seconds: 60)
        noDuration.duration = nil
        #expect(!StreamingCopyPolicy.shouldMake(noDuration))
    }

    @Test func sixtyFramesGetMoreBits() {
        #expect(StreamingCopyPolicy.targetBitsPerSecond(fps: 30) == 2_000_000)
        #expect(StreamingCopyPolicy.targetBitsPerSecond(fps: 60) == 3_000_000)
    }

    @Test func keepsOnlyCopiesThatSaveSpace() {
        #expect(StreamingCopyPolicy.isWorthKeeping(copyBytes: 60, originalBytes: 400))
        #expect(!StreamingCopyPolicy.isWorthKeeping(copyBytes: 300, originalBytes: 400))
        #expect(!StreamingCopyPolicy.isWorthKeeping(copyBytes: 0, originalBytes: 400))
    }

    @Test func noCopyOrOriginalSettingAlwaysPlaysOriginal() {
        #expect(VideoQualityPolicy.initial(preference: .automatic, hasCopy: false, isExpensiveNetwork: true,
                                           bytesPerSecond: 1, originalBitsPerSecond: 50e6) == .original)
        #expect(VideoQualityPolicy.initial(preference: .original, hasCopy: true, isExpensiveNetwork: true,
                                           bytesPerSecond: 1, originalBitsPerSecond: 50e6) == .original)
    }

    @Test func mobileDataPlaysCopy() {
        #expect(VideoQualityPolicy.initial(preference: .automatic, hasCopy: true, isExpensiveNetwork: true,
                                           bytesPerSecond: nil, originalBitsPerSecond: 50e6) == .streamingCopy)
    }

    @Test func automaticAlwaysStartsOnTheFastVersion() {
        // Even on a fast connection: 1080p first, the original only when the user asks for it.
        #expect(VideoQualityPolicy.initial(preference: .automatic, hasCopy: true, isExpensiveNetwork: false,
                                           bytesPerSecond: 50e6, originalBitsPerSecond: 5e6) == .streamingCopy)
    }

    @Test func stallFallbackRespectsTheUser() {
        #expect(VideoQualityPolicy.fallsBackOnStall(playing: .original, preference: .automatic, hasCopy: true, userChose: false))
        #expect(!VideoQualityPolicy.fallsBackOnStall(playing: .original, preference: .automatic, hasCopy: true, userChose: true))
        #expect(!VideoQualityPolicy.fallsBackOnStall(playing: .original, preference: .original, hasCopy: true, userChose: false))
        #expect(!VideoQualityPolicy.fallsBackOnStall(playing: .original, preference: .automatic, hasCopy: false, userChose: false))
        #expect(!VideoQualityPolicy.fallsBackOnStall(playing: .streamingCopy, preference: .automatic, hasCopy: true, userChose: false))
    }

    @Test func throughputIgnoresInstantReads() {
        var t = ThroughputEstimator()
        t.add(bytes: 1 << 20, seconds: 0.01)
        #expect(t.bytesPerSecond == nil)
        t.add(bytes: 1 << 20, seconds: 0.5)
        #expect(t.bytesPerSecond == Double(1 << 21))
        t.add(bytes: 1 << 20, seconds: 1)
        #expect(abs(t.bytesPerSecond! - (Double(1 << 21) + 0.3 * (Double(1 << 20) - Double(1 << 21)))) < 1)
    }

    @Test func resolutionLabels() {
        let fourK = video(mb: 400, seconds: 60)
        #expect(fourK.resolutionLabel(.original) == "4K")
        #expect(fourK.resolutionLabel(.streamingCopy) == "1080p")
        let portrait = video(mb: 100, seconds: 60, w: 1080, h: 1920)
        #expect(portrait.resolutionLabel(.original) == "1080p")
        #expect(portrait.resolutionLabel(.streamingCopy) == "1080p")
        let small = video(mb: 10, seconds: 10, w: 1280, h: 720)
        #expect(small.resolutionLabel(.streamingCopy) == "720p")
        #expect(video(mb: 10, seconds: 10, w: 0, h: 0).resolutionLabel(.original) == nil)
    }

    @Test func streamingCopyNeedsAllParts() {
        var item = video(mb: 400, seconds: 60)
        #expect(!item.hasStreamingCopy)
        item.setParts([RemoteFile(messageId: 1, fileId: "f", fileUniqueId: "u", size: 1)], role: "sp", expected: 2)
        #expect(!item.hasStreamingCopy)
        item.setParts([RemoteFile(messageId: 1, fileId: "f", fileUniqueId: "u", size: 1),
                       RemoteFile(messageId: 2, fileId: "g", fileUniqueId: "v", size: 1)], role: "sp", expected: 2)
        #expect(item.hasStreamingCopy)
        #expect(item.isCompleteInCloud == false) // no "o": the copy never makes an item complete
    }
}

@Suite struct MovieLayoutTests {
    func box(_ type: String, _ size: UInt32) -> Data {
        var d = Data([UInt8(size >> 24), UInt8(size >> 16 & 0xff), UInt8(size >> 8 & 0xff), UInt8(size & 0xff)])
        d.append(contentsOf: Array(type.utf8))
        return d
    }

    @Test func findsIndexAfterMediaData() {
        // ftyp(20) wide(8) mdat(1000) moov(300): the iPhone camera layout.
        var prefix = box("ftyp", 20) + Data(count: 12)
        prefix += box("wide", 8)
        prefix += box("mdat", 1000) + Data(count: 100)
        #expect(MovieLayout.trailingIndexRange(prefix: prefix, totalSize: 1328) == 1028..<1328)
    }

    @Test func indexAtStartNeedsNothing() {
        var prefix = box("ftyp", 20) + Data(count: 12)
        prefix += box("moov", 40) + Data(count: 32)
        prefix += box("mdat", 1000)
        #expect(MovieLayout.trailingIndexRange(prefix: prefix, totalSize: 1060) == nil)
    }

    @Test func largeMediaDataSize() {
        // mdat with a 64-bit size (size field 1).
        var prefix = box("ftyp", 20) + Data(count: 12)
        prefix += box("mdat", 1)
        let big: UInt64 = 5_000_000_000
        prefix += Data((0..<8).map { UInt8(big >> (56 - 8 * UInt64($0)) & 0xff) })
        let total: Int64 = 20 + 5_000_000_000 + 500
        #expect(MovieLayout.trailingIndexRange(prefix: prefix, totalSize: total) == (20 + 5_000_000_000)..<total)
    }

    @Test func impossibleSizesAreRejected() {
        var huge = box("ftyp", 20) + Data(count: 12)
        huge += box("mdat", 1) + Data([0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff])
        #expect(MovieLayout.trailingIndexRange(prefix: huge, totalSize: 1000) == nil)
        var tooLong = box("ftyp", 20) + Data(count: 12)
        tooLong += box("mdat", 5000)
        #expect(MovieLayout.trailingIndexRange(prefix: tooLong, totalSize: 1000) == nil)
    }

    @Test func garbageIsIgnored() {
        #expect(MovieLayout.trailingIndexRange(prefix: Data([0, 0, 0, 2, 1, 2, 3, 4]), totalSize: 100) == nil)
    }
}
