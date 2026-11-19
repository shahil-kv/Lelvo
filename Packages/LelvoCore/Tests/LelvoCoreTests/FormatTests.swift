import Foundation
import CryptoKit
import Testing
import LelvoCore

/// Cross-platform vectors in docs/test-vectors/format1.json. Android must produce identical results.
struct Format1Vectors: Codable {
    var passphrase: String
    var saltHex: String
    var iterations: UInt32
    var masterHex: String
    var keyCheckB64: String
    var header: String
    var captionJSON: String
    var plainCaption: String
    var captionNonceHex: String
    var encryptedCaption: String
    var fileChunkSize: Int
    var filePlaintextLength: Int
    var fileSaltHex: String
    var fileNoncesHex: [String]
    var fileCipherB64: String
}

func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
func unhex(_ s: String) -> Data {
    var d = Data()
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        d.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return d
}

func vectorPlaintext(_ n: Int) -> Data { Data((0..<n).map { UInt8($0 % 251) }) }

func sampleMeta() -> CaptionMeta {
    var m = CaptionMeta(id: "0B7C0E3E-6F1E-4C55-9A33-1F3F0C0A9D10", role: .original, kind: .video,
                        sha256: String(repeating: "ab", count: 32), name: "IMG_4821.MOV", size: 734_003_200)
    m.m = "video/quicktime"
    m.t = 1_729_677_600
    m.tz = 330
    m.g = CaptionMeta.roundedGPS(12.9715987, 77.5945627)
    m.wh = [3840, 2160]
    m.d = 63.2
    m.c = "hevc"
    m.hdr = 2
    m.src = "ios"
    return m
}

@Suite struct CloudFormatTests {
    static let vectorURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/test-vectors/format1.json")

    static func computeVectors() throws -> Format1Vectors {
        let salt = unhex("000102030405060708090a0b0c0d0e0f")
        let keys = try E2EKeys.derive(passphrase: "correct horse battery staple", salt: salt, iterations: 100_000)
        let header = LibraryHeader(encrypted: true, iterations: 100_000, salt: salt, keyCheck: keys.keyCheck)
        let meta = sampleMeta()
        let json = try CaptionCodec.json(meta)
        let nonce = Data(repeating: 0xA0, count: 12)
        let encCaption = CaptionCodec.encryptedPrefix + (try E2EKeys.sealCaptionForTesting(json, key: keys.captionKey, nonce: nonce)).base64EncodedString()
        let fileSalt = unhex("101112131415161718191a1b1c1d1e1f")
        let nonces = (0..<3).map { Data(repeating: UInt8(0xC0 + $0), count: 12) }
        let cipher = try FileCrypto.encryptForTesting(data: vectorPlaintext(10_000), masterKey: keys.master,
                                                      chunkSize: 4096, fileSalt: fileSalt, nonces: nonces)
        return Format1Vectors(passphrase: "correct horse battery staple", saltHex: hex(salt), iterations: 100_000,
                              masterHex: hex(keys.masterData), keyCheckB64: keys.keyCheck.base64EncodedString(),
                              header: header.line, captionJSON: String(decoding: json, as: UTF8.self),
                              plainCaption: try CaptionCodec.encode(meta), captionNonceHex: hex(nonce),
                              encryptedCaption: encCaption, fileChunkSize: 4096, filePlaintextLength: 10_000,
                              fileSaltHex: hex(fileSalt), fileNoncesHex: nonces.map(hex), fileCipherB64: cipher.base64EncodedString())
    }

    @Test func vectorsMatchCommittedFile() throws {
        let computed = try Self.computeVectors()
        if ProcessInfo.processInfo.environment["GENERATE_VECTORS"] == "1" {
            let e = JSONEncoder()
            e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try e.encode(computed).write(to: Self.vectorURL)
        }
        guard let data = try? Data(contentsOf: Self.vectorURL) else {
            // The simulator may not see the repo checkout; the generator run above covers it locally.
            return
        }
        let committed = try JSONDecoder().decode(Format1Vectors.self, from: data)
        #expect(committed.masterHex == computed.masterHex)
        #expect(committed.keyCheckB64 == computed.keyCheckB64)
        #expect(committed.header == computed.header)
        #expect(committed.plainCaption == computed.plainCaption)
        #expect(committed.encryptedCaption == computed.encryptedCaption)
        #expect(committed.fileCipherB64 == computed.fileCipherB64)
    }

    @Test func vectorsDecryptBack() throws {
        let v = try Self.computeVectors()
        let header = try #require(LibraryHeader.parse(LibraryHeader.messagePrefix + v.header))
        let keys = try #require(try header.unlock(passphrase: v.passphrase))
        #expect(try header.unlock(passphrase: "wrong passphrase") == nil)
        #expect(try CaptionCodec.decode(v.encryptedCaption, captionKey: keys.captionKey) == sampleMeta())
        let cipher = try #require(Data(base64Encoded: v.fileCipherB64))
        #expect(try FileCrypto.decrypt(data: cipher, masterKey: keys.master) == vectorPlaintext(10_000))
    }

    @Test func plainCaptionRoundTrip() throws {
        let caption = try CaptionCodec.encode(sampleMeta())
        #expect(caption.hasPrefix("CG1:{"))
        #expect(!caption.contains(" "))
        #expect(try CaptionCodec.decode(caption) == sampleMeta())
        #expect(sampleMeta().latitude == 12.971599)
    }

    @Test func captionRejectsForeignAndNeedsKey() throws {
        #expect(throws: CaptionError.notLelvo) { try CaptionCodec.decode("#cloudgallery id:x role:original") }
        #expect(throws: CaptionError.malformed) { try CaptionCodec.decode("CG1:{not json") }
        let keys = E2EKeys(master: SymmetricKey(size: .bits256))
        let enc = try CaptionCodec.encode(sampleMeta(), captionKey: keys.captionKey)
        #expect(enc.hasPrefix("CG1E:"))
        #expect(throws: CaptionError.encryptedNeedsKey) { try CaptionCodec.decode(enc) }
        #expect(throws: CaptionError.malformed) { try CaptionCodec.decode(enc, captionKey: SymmetricKey(size: .bits256)) }
    }

    @Test func unknownFieldsAreIgnored() throws {
        let caption = #"CG1:{"v":1,"id":"0b7c0e3e-6f1e-4c55-9a33-1f3f0c0a9d10","r":"o","k":"p","h":""# + String(repeating: "0", count: 64) + #"","n":"a.jpg","s":1,"future":{"x":1}}"#
        #expect(try CaptionCodec.decode(caption).n == "a.jpg")
    }

    @Test func longCaptionsAreTrimmedToLimit() throws {
        var m = sampleMeta()
        m.a = (0..<60).map { "Album with a fairly long name \($0)" }
        m.n = String(repeating: "x", count: 900) + ".HEIC"
        let caption = try CaptionCodec.encode(m)
        #expect(caption.count <= CaptionCodec.maxLength)
        let decoded = try CaptionCodec.decode(caption)
        #expect(decoded.a == nil)
        #expect(decoded.n.hasSuffix(".HEIC"))
        let encrypted = try CaptionCodec.encode(m, captionKey: SymmetricKey(size: .bits256))
        #expect(encrypted.count <= CaptionCodec.maxLength)
    }

    /// A real ThumbHash, Base64: what a caption carries in `th`.
    private var sampleHash: String {
        var pixels: [UInt8] = []
        for y in 0..<48 { for x in 0..<64 { pixels += [UInt8(x * 3), UInt8(y * 4), UInt8(255 - x * 2), 255] } }
        return Data(ThumbHash.encode(width: 64, height: 48, rgba: pixels)!).base64EncodedString()
    }

    @Test func thumbHashRoundTripsInPlainAndEncryptedCaptions() throws {
        var m = sampleMeta()
        m.th = sampleHash
        #expect(try CaptionCodec.decode(try CaptionCodec.encode(m)).th == m.th)
        let key = SymmetricKey(size: .bits256)
        #expect(try CaptionCodec.decode(try CaptionCodec.encode(m, captionKey: key), captionKey: key).th == m.th)
        #expect(try CaptionCodec.decode(try CaptionCodec.encode(sampleMeta())).th == nil, "absent stays absent")
    }

    @Test func aThumbHashAddsLittleToATypicalCaption() throws {
        let key = SymmetricKey(size: .bits256)
        var m = sampleMeta()
        let without = try CaptionCodec.encode(m, captionKey: key).count
        m.th = sampleHash
        let with = try CaptionCodec.encode(m, captionKey: key).count
        #expect(with <= CaptionCodec.maxLength)
        #expect(with - without < 80, "grew by \(with - without)")
    }

    @Test func theThumbHashIsDroppedBeforeAnythingElse() throws {
        // Find the album count where the caption fits without `th` but not with it.
        var found = false
        for n in 1...60 {
            var m = sampleMeta()
            m.a = (0..<n).map { "Album with a fairly long name \($0)" }
            let without = try CaptionCodec.encode(m).count
            m.th = sampleHash
            if without <= CaptionCodec.maxLength, CaptionCodec.plainPrefix.count + (try CaptionCodec.json(m)).count > CaptionCodec.maxLength {
                let decoded = try CaptionCodec.decode(try CaptionCodec.encode(m))
                #expect(decoded.th == nil, "th goes first")
                #expect(decoded.a?.count == n, "albums stay")
                #expect(try CaptionCodec.keepsAlbums(m), "th must not push albums out")
                found = true
                break
            }
        }
        #expect(found)
    }

    @Test func aCaptionWithAThumbHashIsReadableByAReaderThatDoesNotKnowIt() throws {
        // The format promises unknown fields are ignored: this is the caption an old build sees.
        let caption = #"CG1:{"v":1,"id":"0b7c0e3e-6f1e-4c55-9a33-1f3f0c0a9d10","r":"o","k":"p","h":""# + String(repeating: "0", count: 64) + #"","n":"a.jpg","s":1,"th":"AAECAwQ=","zz":[1,2]}"#
        let decoded = try CaptionCodec.decode(caption)
        #expect(decoded.n == "a.jpg" && decoded.th == "AAECAwQ=")
    }

    @Test func headerParsing() throws {
        #expect(LibraryHeader.parse("CloudGallery Library\ncg:1") == .plain)
        #expect(LibraryHeader.parse("#cloudgallery-library cg:1") == .plain)
        #expect(LibraryHeader.parse("hello") == nil)
        #expect(LibraryHeader.parse("cg:1;e2e:1;it:50;s:AAAAAAAAAAAAAAAAAAAAAA==;kc:AAAAAAAAAAAAAAAAAAAAAA==") == nil) // too few iterations
        let (h, _) = try LibraryHeader.newEncrypted(passphrase: "pw-for-test", iterations: 100_000)
        #expect(LibraryHeader.parse(h.messageText) == h)
    }
}

@Suite struct RandomAccessTests {
    let key = SymmetricKey(size: .bits256)

    @Test(arguments: [0, 1, 4095, 4096, 4097, 20_000])
    func anyRangeDecryptsIndependently(size: Int) throws {
        let plain = vectorPlaintext(size)
        let cipher = try FileCrypto.encryptForTesting(data: plain, masterKey: key, chunkSize: 4096,
                                                      fileSalt: KeyDerivation.randomSalt(),
                                                      nonces: (0..<10).map { _ in Data((0..<12).map { _ in UInt8.random(in: 0...255) }) })
        let reader = try CGFERandomReader(header: cipher.prefix(25), cipherSize: Int64(cipher.count), master: key)
        #expect(reader.layout.plaintextSize == Int64(size))
        var fetched = 0
        let fetch: (Range<Int64>) throws -> Data = { r in
            fetched += Int(r.count)
            return cipher[Int(r.lowerBound) ..< Int(r.upperBound)]
        }
        let ranges: [Range<Int64>] = [0..<Int64(size), 0..<min(10, Int64(size)), Int64(size / 2)..<Int64(size),
                                      Int64(max(0, size - 3))..<Int64(size + 50)]
        for r in ranges {
            let lo = Int(max(0, r.lowerBound)), hi = Int(min(Int64(size), r.upperBound))
            let expected = lo < hi ? plain[lo..<hi] : Data()
            #expect(try reader.read(r, fetch: fetch) == expected)
        }
        if size == 20_000 {
            fetched = 0
            _ = try reader.read(9000..<9010, fetch: fetch)
            #expect(fetched == 4096 + 28) // only one chunk fetched for a small seek
        }
    }

    @Test func tamperedChunkFails() throws {
        var cipher = try FileCrypto.encrypt(data: vectorPlaintext(9000), masterKey: key)
        cipher[cipher.count - 1] ^= 1
        let reader = try CGFERandomReader(header: cipher.prefix(25), cipherSize: Int64(cipher.count), master: key)
        #expect(throws: CryptoError.self) { try reader.read(0..<9000) { cipher[Int($0.lowerBound)..<Int($0.upperBound)] } }
    }
}

@Suite struct SplitLayoutTests {
    @Test func partSizeForLimits() {
        #expect(PartLayout.partSize(forLimit: PartLayout.standardLimit) == 1999 * PartLayout.mib)
        #expect(PartLayout.partSize(forLimit: PartLayout.premiumLimit) == 3999 * PartLayout.mib)
    }

    @Test func noSplitUnderLimit() {
        let l = PartLayout.forUpload(size: 1_000, limit: PartLayout.standardLimit)
        #expect(!l.isSplit)
        #expect(l.partCount == 1)
        #expect(l.segments(for: 10..<20) == [.init(part: 0, offset: 10, length: 10)])
    }

    @Test func rangesCrossingPartBoundaries() {
        let l = PartLayout(partSize: 100, totalSize: 250)
        #expect(l.partCount == 3)
        #expect(l.size(ofPart: 2) == 50)
        #expect(l.segments(for: 90..<210) == [.init(part: 0, offset: 90, length: 10),
                                              .init(part: 1, offset: 0, length: 100),
                                              .init(part: 2, offset: 0, length: 10)])
        #expect(l.segments(for: 240..<400) == [.init(part: 2, offset: 40, length: 10)])
        let big = PartLayout.forUpload(size: 5 * 1024 * PartLayout.mib, limit: PartLayout.standardLimit)
        #expect(big.partCount == 3)
    }

    @Test func spaceNeededForPlainUnsplitIsJustTheExport() {
        // An unsplit plain file is hard-linked into the upload, so it needs no second copy.
        #expect(PartLayout.spaceNeeded(exportSizes: [500 * PartLayout.mib, 3 * PartLayout.mib], encrypted: false,
                                       limit: PartLayout.standardLimit) == 503 * PartLayout.mib)
    }

    @Test func spaceNeededForPlainSplitAddsOnePart() {
        let video = 5 * 1024 * PartLayout.mib
        #expect(PartLayout.spaceNeeded(exportSizes: [video], encrypted: false, limit: PartLayout.standardLimit)
                == video + 1999 * PartLayout.mib)
        #expect(PartLayout.spaceNeeded(exportSizes: [video], encrypted: false, limit: PartLayout.premiumLimit)
                == video + 3999 * PartLayout.mib)
    }

    @Test func spaceNeededForEncryptedAddsTheLargestFirstPart() {
        let photo = 3 * PartLayout.mib, video = 700 * PartLayout.mib
        #expect(PartLayout.spaceNeeded(exportSizes: [photo, video], encrypted: true, limit: PartLayout.standardLimit)
                == photo + video + FileCrypto.encryptedSize(plaintextSize: video))
        let big = 5 * 1024 * PartLayout.mib
        #expect(PartLayout.spaceNeeded(exportSizes: [big], encrypted: true, limit: PartLayout.standardLimit)
                == big + 1999 * PartLayout.mib)
        #expect(PartLayout.spaceNeeded(exportSizes: [], encrypted: true, limit: PartLayout.standardLimit) == 0)
    }
}

@Suite struct JobMachineTests {
    let now = Date(timeIntervalSince1970: 1_000)

    @Test func happyPath() {
        var j = JobStatus()
        j = JobMachine.reduce(j, .start, now: now)
        #expect(j.state == .uploading)
        j = JobMachine.reduce(j, .sent(sizeMatches: true), now: now)
        #expect(j.state == .verified)
        #expect(JobMachine.reduce(j, .retry, now: now).state == .verified)
    }

    @Test func floodWaitDoesNotCountAsAttempt() {
        var j = JobMachine.reduce(JobStatus(), .start, now: now)
        j = JobMachine.reduce(j, .floodWait(seconds: 42), now: now)
        #expect(j.state == .pending)
        #expect(j.attempts == 0)
        #expect(j.notBefore == now.addingTimeInterval(42))
        #expect(!j.isRunnable(at: now))
        #expect(j.isRunnable(at: now.addingTimeInterval(42)))
    }

    @Test func transientErrorsBackOffThenFail() {
        var j = JobStatus()
        for attempt in 1...JobMachine.maxAttempts {
            j = JobMachine.reduce(j, .start, now: now)
            j = JobMachine.reduce(j, .error(reason: "network", transient: true), now: now)
            #expect(j.attempts == attempt)
            if attempt < JobMachine.maxAttempts {
                #expect(j.state == .pending)
                #expect(j.notBefore! > now)
                j.notBefore = nil
            }
        }
        #expect(j.state == .failed)
        j = JobMachine.reduce(j, .retry, now: now)
        #expect(j == JobStatus(state: .pending))
    }

    @Test func sizeMismatchAndPermanentErrorsFail() {
        let up = JobMachine.reduce(JobStatus(), .start, now: now)
        #expect(JobMachine.reduce(up, .sent(sizeMatches: false), now: now).state == .failed)
        let perm = JobMachine.reduce(up, .error(reason: "FILE_REFERENCE_EXPIRED", transient: false), now: now)
        #expect(perm.state == .failed)
        #expect(perm.lastError == "FILE_REFERENCE_EXPIRED")
        #expect(JobMachine.reduce(up, .interrupted, now: now).state == .pending)
    }

    @Test func backoffKeepsRetryWaiting() {
        var j = JobMachine.reduce(JobStatus(), .start, now: now)
        j = JobMachine.reduce(j, .error(reason: "network", transient: true), now: now)
        #expect(j.state == .pending)
        #expect(!j.isRunnable(at: now))
        #expect(!j.isRunnable(at: j.notBefore!.addingTimeInterval(-0.5)))
        #expect(j.isRunnable(at: j.notBefore!))
    }

    @Test func autoRetryOnlyTransientOncePerDay() {
        var j = JobStatus()
        for _ in 1...JobMachine.maxAttempts {
            j = JobMachine.reduce(j, .start, now: now)
            j = JobMachine.reduce(j, .error(reason: "network", transient: true), now: now)
            j.notBefore = nil
        }
        #expect(j.state == .failed && j.transientFailure)
        let retried = JobMachine.autoRetry(j, now: now)
        #expect(retried?.state == .pending)
        #expect(retried?.attempts == 0)
        #expect(retried?.autoRetriedAt == now)
        // Fails again the same day: left for the user.
        var again = retried!
        again.state = .failed; again.transientFailure = true; again.attempts = JobMachine.maxAttempts
        #expect(JobMachine.autoRetry(again, now: now.addingTimeInterval(3600)) == nil)
        #expect(JobMachine.autoRetry(again, now: now.addingTimeInterval(JobMachine.autoRetryInterval))?.state == .pending)

        let up = JobMachine.reduce(JobStatus(), .start, now: now)
        let perm = JobMachine.reduce(up, .error(reason: "missing original", transient: false), now: now)
        #expect(JobMachine.autoRetry(perm, now: now) == nil)
        #expect(JobMachine.autoRetry(JobMachine.reduce(up, .sent(sizeMatches: false), now: now), now: now) == nil)
        #expect(JobMachine.autoRetry(up, now: now) == nil)
    }

    @Test func floodWaitParsing() {
        #expect(TelegramErrorClassifier.classify(code: 429, message: "Too Many Requests: retry after 17") == .floodWait(seconds: 17))
        #expect(TelegramErrorClassifier.classify(code: 420, message: "FLOOD_WAIT_300") == .floodWait(seconds: 300))
        #expect(TelegramErrorClassifier.classify(code: 420, message: "FLOOD_PREMIUM_WAIT_8") == .floodWait(seconds: 8))
        #expect(TelegramErrorClassifier.classify(code: 401, message: "Unauthorized") == .auth)
        #expect(TelegramErrorClassifier.classify(code: 500, message: "Internal") == .transient)
        #expect(TelegramErrorClassifier.classify(code: 400, message: "Network error") == .transient)
        #expect(TelegramErrorClassifier.classify(code: 400, message: "CHAT_WRITE_FORBIDDEN") == .permanent)
    }
}

@Suite struct ThumbHashTests {
    /// A smooth made-up picture: warm on the left, cool on the right, brighter at the top.
    private func gradient(_ w: Int, _ h: Int, alpha: Bool = false) -> [UInt8] {
        var out: [UInt8] = []
        for y in 0..<h { for x in 0..<w {
            let fx = Double(x) / Double(max(1, w - 1)), fy = Double(y) / Double(max(1, h - 1))
            out += [UInt8(220 - 160 * fx), UInt8(120 + 40 * fy), UInt8(60 + 160 * fx), alpha ? UInt8(255 * (1 - 0.5 * fy)) : 255]
        } }
        return out
    }

    @Test func aHashIsAboutTwentyFiveBytes() throws {
        for (w, h) in [(100, 100), (100, 56), (56, 100), (4, 3), (1, 1)] {
            let hash = try #require(ThumbHash.encode(width: w, height: h, rgba: gradient(w, h)))
            #expect(hash.count >= 5 && hash.count <= 25, "\(w)x\(h) gave \(hash.count) bytes")
        }
        #expect(try #require(ThumbHash.encode(width: 64, height: 48, rgba: gradient(64, 48, alpha: true))).count <= 28)
    }

    @Test func decodingKeepsTheColoursAndTheShape() throws {
        let hash = try #require(ThumbHash.encode(width: 100, height: 56, rgba: gradient(100, 56)))
        let image = try #require(ThumbHash.decode(hash))
        #expect(image.width == 32 && image.height > 0 && image.height < 32, "landscape stays landscape")
        #expect(image.rgba.count == image.width * image.height * 4)
        #expect(abs(try #require(ThumbHash.aspectRatio(hash)) - 100.0 / 56.0) < 0.35)
        // Left edge is warmer (more red than blue) and the right edge is cooler, as in the source.
        let y = image.height / 2
        let left = (y * image.width) * 4, right = (y * image.width + image.width - 1) * 4
        #expect(image.rgba[left] > image.rgba[left + 2])
        #expect(image.rgba[right + 2] > image.rgba[right])
    }

    @Test func sameInputGivesTheSameHash() throws {
        let a = try #require(ThumbHash.encode(width: 80, height: 60, rgba: gradient(80, 60)))
        let b = try #require(ThumbHash.encode(width: 80, height: 60, rgba: gradient(80, 60)))
        #expect(a == b)
    }

    @Test func badInputIsRefusedNotCrashed() {
        #expect(ThumbHash.encode(width: 0, height: 10, rgba: []) == nil)
        #expect(ThumbHash.encode(width: 101, height: 10, rgba: [UInt8](repeating: 0, count: 101 * 10 * 4)) == nil)
        #expect(ThumbHash.encode(width: 10, height: 10, rgba: [1, 2, 3]) == nil)
    }

    @Test func damagedHashesReturnNilAndNeverCrash() throws {
        let good = try #require(ThumbHash.encode(width: 64, height: 64, rgba: gradient(64, 64)))
        #expect(ThumbHash.decode([]) == nil)
        #expect(ThumbHash.decode([1, 2, 3, 4]) == nil)
        #expect(ThumbHash.decode(Array(good.dropLast(3))) == nil, "a cut-off hash")
        #expect(ThumbHash.aspectRatio([9]) == nil)
        // Random bytes of any length must give an image or nil, never a crash or an enormous image.
        var seed: UInt64 = 42
        for length in 0..<40 {
            var bytes: [UInt8] = []
            for _ in 0..<length { seed = seed &* 6364136223846793005 &+ 1442695040888963407; bytes.append(UInt8(truncatingIfNeeded: seed >> 33)) }
            if let image = ThumbHash.decode(bytes) {
                #expect(image.width >= 1 && image.width <= 32 && image.height >= 1 && image.height <= 32)
                #expect(image.rgba.count == image.width * image.height * 4)
            }
        }
    }
}

/// Cross-platform vectors in docs/test-vectors/thumbhash1.json, made with the reference algorithm. Android must match.
@Suite struct ThumbHashVectorTests {
    private struct Vector: Decodable {
        let name: String; let w: Int; let h: Int; let seed: Int; let alpha: Bool
        let hash: String; let decodedWidth: Int; let decodedHeight: Int; let decodedRGBA: String
    }
    private struct File: Decodable { let vectors: [Vector] }

    private func load() throws -> [Vector] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("docs/test-vectors/thumbhash1.json"))
        return try JSONDecoder().decode(File.self, from: data).vectors
    }

    private func pixels(_ v: Vector) -> [UInt8] {
        var out: [UInt8] = []
        for y in 0..<v.h { for x in 0..<v.w {
            out += [UInt8((x * 37 + y * 11 + v.seed * 53) % 256), UInt8((x * 5 + y * 29 + v.seed * 91) % 256),
                    UInt8((x * y + v.seed * 17) % 256), v.alpha ? UInt8(((x + y) * 8) % 256) : 255]
        } }
        return out
    }

    @Test func encodingMatchesTheReferenceExactly() throws {
        for v in try load() {
            let hash = try #require(ThumbHash.encode(width: v.w, height: v.h, rgba: pixels(v)), "\(v.name)")
            #expect(hash.map { String(format: "%02x", $0) }.joined() == v.hash, "\(v.name)")
        }
    }

    @Test func decodingMatchesTheReferenceWithinOneLevel() throws {
        for v in try load() {
            let bytes = stride(from: 0, to: v.hash.count, by: 2).map { UInt8(v.hash.dropFirst($0).prefix(2), radix: 16)! }
            let image = try #require(ThumbHash.decode(bytes), "\(v.name)")
            #expect(image.width == v.decodedWidth && image.height == v.decodedHeight, "\(v.name) size")
            let expected = [UInt8](try #require(Data(base64Encoded: v.decodedRGBA)))
            #expect(expected.count == image.rgba.count, "\(v.name) length")
            let worst = zip(expected, image.rgba).map { abs(Int($0) - Int($1)) }.max() ?? 0
            #expect(worst <= 1, "\(v.name) differs by \(worst)")
        }
    }
}
