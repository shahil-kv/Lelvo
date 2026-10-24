import Foundation
import CryptoKit
import Testing
import MemvoCore

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
        #expect(throws: CaptionError.notMemvo) { try CaptionCodec.decode("#cloudgallery id:x role:original") }
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
