import Foundation
import CryptoKit
import Testing
import MemvoCore

@Suite struct KeyDerivationTests {
    private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    @Test func pbkdf2MatchesKnownVectors() throws {
        let salt = Data("salt".utf8)
        #expect(hex(try KeyDerivation.pbkdf2(passphrase: "password", salt: salt, iterations: 1))
                == "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
        #expect(hex(try KeyDerivation.pbkdf2(passphrase: "password", salt: salt, iterations: 2))
                == "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43")
        #expect(hex(try KeyDerivation.pbkdf2(passphrase: "password", salt: salt, iterations: 4096))
                == "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
    }

    @Test func defaultWorkFactorIsAtLeast200k() {
        #expect(KeyDerivation.defaultIterations >= 200_000)
        #expect(KeyDerivation.minimumIterations >= 200_000)
    }

    @Test func saltChangesKeyAndIsRandom() throws {
        let a = KeyDerivation.randomSalt(), b = KeyDerivation.randomSalt()
        #expect(a.count == 16)
        #expect(a != b)
        #expect(try KeyDerivation.pbkdf2(passphrase: "pw", salt: a, iterations: 1000)
                != KeyDerivation.pbkdf2(passphrase: "pw", salt: b, iterations: 1000))
        #expect(try KeyDerivation.pbkdf2(passphrase: "pw", salt: a, iterations: 1000)
                == KeyDerivation.pbkdf2(passphrase: "pw", salt: a, iterations: 1000))
    }

    @Test func emptyPassphraseIsRejected() {
        #expect(throws: CryptoError.derivationFailed) {
            try KeyDerivation.pbkdf2(passphrase: "", salt: Data([1, 2, 3]), iterations: 1)
        }
    }

    @Test func unicodeNormalisationIsStable() throws {
        let salt = Data("s".utf8)
        // "é" precomposed vs. decomposed must derive the same key.
        #expect(try KeyDerivation.pbkdf2(passphrase: "caf\u{00E9}", salt: salt, iterations: 10)
                == KeyDerivation.pbkdf2(passphrase: "cafe\u{0301}", salt: salt, iterations: 10))
    }
}

@Suite struct IndexEncryptionTests {
    func sampleIndex(count: Int = 3) -> CloudIndex {
        let items = (0..<count).map { i -> MediaItem in
            var item = MediaItem(localIdentifier: "LOCAL-\(i)", sha256: String(repeating: "a", count: 64),
                                   filename: "IMG_\(i).HEIC", kind: i % 2 == 0 ? .photo : .livePhoto,
                                   creationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)),
                                   latitude: 48.85, longitude: 2.35, pixelWidth: 4032, pixelHeight: 3024,
                                   fileSize: 2_000_000, status: .backedUp)
            item.original = RemoteFile(messageId: Int64(i * 2 + 1), fileId: "file\(i)", fileUniqueId: "u\(i)", size: 2_000_000)
            item.thumbnail = RemoteFile(messageId: Int64(i * 2 + 2), fileId: "thumb\(i)", fileUniqueId: "t\(i)", size: 30_000)
            return item
        }
        return CloudIndex(createdAt: Date(timeIntervalSince1970: 1_700_000_500), deviceName: "Test iPhone",
                          fileKeySalt: Data(repeating: 7, count: 16), items: items)
    }

    @Test func indexRoundTrip() throws {
        let index = sampleIndex()
        let sealed = try IndexCodec.seal(.index(index), passphrase: "correct horse battery staple")
        #expect(sealed.prefix(4) == Data("CGIX".utf8))
        let header = try PassphraseBox.header(of: sealed)
        #expect(header.iterations >= 200_000)
        #expect(try IndexCodec.open(sealed, passphrase: "correct horse battery staple") == .index(index))
    }

    @Test func manifestRoundTrip() throws {
        let manifest = IndexManifest(createdAt: Date(timeIntervalSince1970: 1_700_000_000), totalSize: 42, sha256: "abc",
                                     chunks: [RemoteFile(messageId: 1, fileId: "f", fileUniqueId: "u", size: 42)])
        let sealed = try IndexCodec.seal(.manifest(manifest), passphrase: "pw")
        #expect(try IndexCodec.open(sealed, passphrase: "pw") == .manifest(manifest))
    }

    @Test func wrongPassphraseFails() throws {
        let sealed = try IndexCodec.seal(.index(sampleIndex()), passphrase: "right")
        #expect(throws: CryptoError.wrongPassphraseOrCorrupt) { try IndexCodec.open(sealed, passphrase: "wrong") }
    }

    @Test func tamperingIsDetected() throws {
        var sealed = try PassphraseBox.seal(Data("hello".utf8), passphrase: "pw", iterations: 1000)
        sealed[sealed.count - 1] ^= 0xFF
        #expect(throws: CryptoError.wrongPassphraseOrCorrupt) { try PassphraseBox.open(sealed, passphrase: "pw") }

        var header = try PassphraseBox.seal(Data("hello".utf8), passphrase: "pw", iterations: 1000)
        header[10] ^= 0x01 // flip a salt bit: key changes and header AAD no longer matches
        #expect(throws: CryptoError.wrongPassphraseOrCorrupt) { try PassphraseBox.open(header, passphrase: "pw") }
    }

    @Test func freshSaltEveryTime() throws {
        let a = try PassphraseBox.seal(Data("x".utf8), passphrase: "pw", iterations: 1000)
        let b = try PassphraseBox.seal(Data("x".utf8), passphrase: "pw", iterations: 1000)
        #expect(try PassphraseBox.header(of: a).salt != PassphraseBox.header(of: b).salt)
        #expect(a != b)
    }

    @Test func rejectsForeignData() {
        #expect(throws: CryptoError.badFormat) { try PassphraseBox.header(of: Data(repeating: 0x41, count: 100)) }
        #expect(throws: CryptoError.truncated) { try PassphraseBox.header(of: Data("CGIX".utf8)) }
    }

    @Test func largeIndexIsSplitAndReassembled() throws {
        let blob = Data((0..<10_000).map { UInt8($0 % 251) })
        let chunks = IndexCodec.split(blob, maxChunk: 3_000)
        #expect(chunks.count == 4)
        #expect(chunks.dropLast().allSatisfy { $0.count == 3_000 })
        #expect(chunks.reduce(Data(), +) == blob)
        #expect(IndexCodec.split(Data([1, 2]), maxChunk: 3_000) == [Data([1, 2])])
    }
}

@Suite struct FileCryptoTests {
    let key = SymmetricKey(size: .bits256)

    @Test(arguments: [0, 1, 999, 1000, 1001, 5000])
    func roundTripAcrossChunkBoundaries(size: Int) throws {
        let plain = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let dir = FileManager.default.temporaryDirectory
        let a = dir.appendingPathComponent(UUID().uuidString), b = dir.appendingPathComponent(UUID().uuidString),
            c = dir.appendingPathComponent(UUID().uuidString)
        defer { [a, b, c].forEach { try? FileManager.default.removeItem(at: $0) } }
        try plain.write(to: a)
        try FileCrypto.encrypt(input: a, output: b, masterKey: key, chunkSize: 1000)
        let cipher = try Data(contentsOf: b)
        #expect(Int64(cipher.count) == FileCrypto.encryptedSize(plaintextSize: Int64(size), chunkSize: 1000))
        #expect(FileCrypto.isEncrypted(cipher))
        try FileCrypto.decrypt(input: b, output: c, masterKey: key)
        #expect(try Data(contentsOf: c) == plain)
    }

    @Test func truncationAndWrongKeyAreDetected() throws {
        let plain = Data(repeating: 9, count: 3 * FileCrypto.defaultChunkSize)
        let cipher = try FileCrypto.encrypt(data: plain, masterKey: key)
        #expect(try FileCrypto.decrypt(data: cipher, masterKey: key) == plain)
        // Drop the final chunk: the new last chunk was not sealed as final.
        let truncated = cipher.prefix(cipher.count - (FileCrypto.defaultChunkSize + 28))
        #expect(throws: CryptoError.self) { try FileCrypto.decrypt(data: Data(truncated), masterKey: key) }
        #expect(throws: CryptoError.self) { try FileCrypto.decrypt(data: cipher, masterKey: SymmetricKey(size: .bits256)) }
    }
}

@Suite struct FastVersionChunkTests {
    /// Fast versions are written with 256 KiB chunks; random reads (what the player does) must still return the exact
    /// plaintext, across chunk boundaries and at the short last chunk.
    @Test func smallChunksDecryptAnyRange() throws {
        let master = SymmetricKey(size: .bits256)
        let plain = Data((0..<(FileCrypto.fastVersionChunkSize * 3 + 1234)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let dir = FileManager.default.temporaryDirectory
        let input = dir.appendingPathComponent(UUID().uuidString), output = dir.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: input); try? FileManager.default.removeItem(at: output) }
        try plain.write(to: input)
        try FileCrypto.encrypt(input: input, output: output, masterKey: master, chunkSize: FileCrypto.fastVersionChunkSize)
        let cipher = try Data(contentsOf: output)
        #expect(Int64(cipher.count) == FileCrypto.encryptedSize(plaintextSize: Int64(plain.count), chunkSize: FileCrypto.fastVersionChunkSize))

        let reader = try CGFERandomReader(header: cipher.prefix(25), cipherSize: Int64(cipher.count), master: master)
        #expect(reader.layout.chunkSize == FileCrypto.fastVersionChunkSize)
        #expect(reader.layout.plaintextSize == Int64(plain.count))
        let fetch: (Range<Int64>) throws -> Data = { cipher.subdata(in: Int($0.lowerBound)..<Int($0.upperBound)) }
        let k = Int64(FileCrypto.fastVersionChunkSize)
        for range in [0..<512 << 10, k - 10..<k + 10, 2 * k..<3 * k, Int64(plain.count) - 100..<Int64(plain.count)] as [Range<Int64>] {
            #expect(try reader.read(range, fetch: fetch) == plain.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)))
        }
    }
}

@Suite struct DecryptedChunkCacheTests {
    let master = SymmetricKey(size: .bits256)
    let chunk = 4096

    func encrypted(_ size: Int) throws -> (plain: Data, cipher: Data) {
        let plain = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let dir = FileManager.default.temporaryDirectory
        let input = dir.appendingPathComponent(UUID().uuidString), output = dir.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: input); try? FileManager.default.removeItem(at: output) }
        try plain.write(to: input)
        try FileCrypto.encrypt(input: input, output: output, masterKey: master, chunkSize: chunk)
        return (plain, try Data(contentsOf: output))
    }

    /// Player-sized pieces read through the cache equal the plaintext, at chunk boundaries and the short last chunk,
    /// and each chunk is fetched (and decrypted) once.
    @Test func cachedReadsMatchFreshOnesAndFetchEachChunkOnce() async throws {
        let (plain, cipher) = try encrypted(chunk * 5 + 123)
        let reader = try CGFERandomReader(header: cipher.prefix(25), cipherSize: Int64(cipher.count), master: master)
        let cache = DecryptedChunkCache(limit: 64 << 10)
        var fetched: [Range<Int64>] = []
        let fetch: (Range<Int64>) async throws -> Data = { range in
            fetched.append(range)
            return cipher.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
        }
        let c = Int64(chunk), total = Int64(plain.count)
        for start in stride(from: Int64(0), to: total, by: 1000) {
            let range = start ..< min(total, start + 1000)
            let data = try await reader.read(range, cache: cache, file: "a/o", fetch: fetch)
            #expect(data == plain.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)))
        }
        #expect(fetched.count == Int(reader.layout.chunkCount))
        for range in [c - 10 ..< c + 10, 0 ..< total, total - 5 ..< total + 50] as [Range<Int64>] {
            let data = try await reader.read(range, cache: cache, file: "a/o", fetch: fetch)
            #expect(data == plain.subdata(in: Int(range.lowerBound)..<Int(min(range.upperBound, total))))
        }
        #expect(fetched.count == Int(reader.layout.chunkCount))
    }

    @Test func staysWithinItsLimitAndForgetsAFile() {
        let cache = DecryptedChunkCache(limit: 10)
        cache.store("a", 0, Data(count: 4))
        cache.store("a", 1, Data(count: 4))
        #expect(cache.chunk("a", 0) != nil) // now the most recently used
        cache.store("b", 0, Data(count: 4))
        #expect(cache.totalBytes == 8)
        #expect(cache.chunk("a", 1) == nil)
        #expect(cache.chunk("a", 0) != nil)
        cache.remove(file: "a")
        #expect(cache.chunk("a", 0) == nil)
        #expect(cache.chunk("b", 0) != nil)
        #expect(cache.totalBytes == 4)
    }
}

@Suite struct StreamingEncryptorTests {
    let master = SymmetricKey(size: .bits256)

    /// Reading the ciphertext in pieces of any size (as split parts do) gives exactly the whole-file output for the same
    /// salt and nonces, at chunk boundaries, for an empty file and for exactly one chunk.
    @Test(arguments: [0, 1, 999, 1000, 1001, 2000, 5432])
    func piecesEqualTheWholeFile(size: Int) throws {
        let chunk = 1000
        let plain = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        let salt = Data(repeating: 7, count: 16)
        let count = max(1, (size + chunk - 1) / chunk)
        let nonces = (0..<count).map { i in Data((0..<12).map { UInt8(truncatingIfNeeded: $0 + i * 12) }) }
        let whole = try FileCrypto.encryptForTesting(data: plain, masterKey: master, chunkSize: chunk, fileSalt: salt, nonces: nonces)
        #expect(try FileCrypto.decrypt(data: whole, masterKey: master) == plain)

        let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: input) }
        try plain.write(to: input)
        for piece in [1, 25, 999, 1028, 4096] {
            let encryptor = try FileCrypto.Encryptor.forTesting(input: input, masterKey: master, chunkSize: chunk, fileSalt: salt, nonces: nonces)
            #expect(encryptor.cipherSize == Int64(whole.count))
            var joined = Data()
            while true {
                let bytes = try encryptor.read(upToCount: piece)
                if bytes.isEmpty { break }
                #expect(bytes.count <= piece)
                joined.append(bytes)
            }
            #expect(joined == whole)
        }
    }

    /// An upload interrupted after any number of bytes (inside the header, on a chunk boundary, inside a nonce or a
    /// tag, at the end) carries on from its resume point: the joined stream decrypts to the original, and with the same
    /// nonces it is byte for byte the whole-file output.
    @Test(arguments: [0, 3, 25, 26, 37, 1000, 1053, 1054, 1060, 2081, 4000, 5625])
    func resumesFromAnyCut(cut: Int) throws {
        let chunk = 1000
        let plain = Data((0..<5432).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let salt = Data(repeating: 9, count: 16)
        let nonces = (0..<6).map { i in Data((0..<12).map { UInt8(truncatingIfNeeded: $0 * 7 + i) }) }
        let whole = try FileCrypto.encryptForTesting(data: plain, masterKey: master, chunkSize: chunk, fileSalt: salt, nonces: nonces)
        #expect(whole.count == 5625)

        let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: input) }
        try plain.write(to: input)
        let first = try FileCrypto.Encryptor.forTesting(input: input, masterKey: master, chunkSize: chunk, fileSalt: salt, nonces: nonces)
        let uploaded = try first.read(upToCount: cut)
        let point = first.resumePoint(plaintextHash: "h")
        #expect(point.cipherOffset == Int64(cut))
        #expect(point.fileSalt == salt)

        // Survives being saved with the job, as it is between launches.
        let saved = try JSONDecoder().decode(FileCrypto.ResumePoint.self, from: JSONEncoder().encode(point))
        let same = try FileCrypto.Encryptor.forTesting(input: input, masterKey: master, resumingAt: saved, nonces: nonces)
        #expect(same.resumePoint(plaintextHash: "h") == point)
        #expect(uploaded + (try readAll(same)) == whole)

        let fresh = try FileCrypto.Encryptor(input: input, masterKey: master, resumingAt: saved)
        let joined = uploaded + (try readAll(fresh))
        #expect(joined.count == whole.count)
        #expect(try FileCrypto.decrypt(data: joined, masterKey: master) == plain)
    }

    /// Cut in the middle of a chunk without its nonce: refused rather than sealing with a new one, which wouldn't decrypt.
    @Test func resumeInsideAChunkNeedsItsNonce() throws {
        let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: input) }
        try Data(repeating: 1, count: 3000).write(to: input)
        let point = FileCrypto.ResumePoint(cipherOffset: 1500, chunkSize: 1000, fileSalt: Data(repeating: 2, count: 16),
                                           nonce: nil, plaintextHash: "h")
        #expect(throws: CryptoError.self) { try FileCrypto.Encryptor(input: input, masterKey: master, resumingAt: point) }
    }

    /// Parts in the real layout (whole MiB) and 1 MiB chunks: every cut falls inside a chunk, so the nonce is kept.
    @Test func partCutsNeedTheCrossingChunksNonce() throws {
        let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: input) }
        try Data(repeating: 3, count: 5 << 20).write(to: input)
        let encryptor = try FileCrypto.Encryptor(input: input, masterKey: master)
        let layout = PartLayout.forUpload(size: encryptor.cipherSize, limit: 3 << 20)
        #expect(layout.partCount == 3)
        _ = try encryptor.read(upToCount: Int(layout.partSize))
        #expect(encryptor.resumePoint(plaintextHash: "h").nonce?.count == 12)
    }

    /// The upload as the app does it: parts 0 and 1 written and the app quits; a new launch resumes from part 2 with the
    /// saved point and fresh nonces. The joined parts decrypt to the original, byte for byte.
    @Test func splitUploadResumesFromPartTwo() throws {
        let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: input) }
        let plain = Data((0..<(7 << 20) + 12345).map { UInt8(truncatingIfNeeded: $0 &* 2654435761 >> 7) })
        try plain.write(to: input)
        let first = try FileCrypto.Encryptor(input: input, masterKey: master)
        let layout = PartLayout.forUpload(size: first.cipherSize, limit: 3 << 20)
        #expect(layout.partCount == 4)

        var parts: [Data] = []
        for index in 0..<2 { parts.append(try first.read(upToCount: Int(layout.size(ofPart: index)))) }
        let saved = try JSONEncoder().encode(first.resumePoint(plaintextHash: "h"))

        let point = try JSONDecoder().decode(FileCrypto.ResumePoint.self, from: saved)
        #expect(point.continues(partSizes: parts.map { Int64($0.count) }, layout: layout,
                                chunkSize: FileCrypto.defaultChunkSize, plaintextHash: "h"))
        let resumed = try FileCrypto.Encryptor(input: input, masterKey: master, resumingAt: point)
        for index in 2..<layout.partCount {
            let part = try resumed.read(upToCount: Int(layout.size(ofPart: index)))
            #expect(Int64(part.count) == layout.size(ofPart: index))
            parts.append(part)
        }
        #expect(try resumed.read(upToCount: 1).isEmpty)
        #expect(try FileCrypto.decrypt(data: parts.reduce(Data(), +), masterKey: master) == plain)
    }

    /// A retry continues only from the exact end of the confirmed parts, for the same file, chunk size and part layout.
    @Test func resumePointMustMatchTheConfirmedParts() {
        let layout = PartLayout(partSize: 1000, totalSize: 3500)
        let point = FileCrypto.ResumePoint(cipherOffset: 2000, chunkSize: 100, fileSalt: Data(repeating: 1, count: 16),
                                           nonce: Data(repeating: 2, count: 12), plaintextHash: "h")
        #expect(point.continues(partSizes: [1000, 1000], layout: layout, chunkSize: 100, plaintextHash: "h"))
        #expect(!point.continues(partSizes: [1000], layout: layout, chunkSize: 100, plaintextHash: "h"))
        #expect(!point.continues(partSizes: [], layout: layout, chunkSize: 100, plaintextHash: "h"))
        #expect(!point.continues(partSizes: [1000, 1000], layout: layout, chunkSize: 100, plaintextHash: "other file"))
        #expect(!point.continues(partSizes: [1000, 1000], layout: layout, chunkSize: 200, plaintextHash: "h"))
        // The account limit changed (Premium), so the parts have another size.
        #expect(!point.continues(partSizes: [1000, 1000], layout: PartLayout(partSize: 2000, totalSize: 3500), chunkSize: 100, plaintextHash: "h"))
        #expect(!point.continues(partSizes: [1000, 999], layout: layout, chunkSize: 100, plaintextHash: "h"))
    }

    /// The point is kept only while some parts are missing, and goes when the parts are cleared or complete.
    @Test func resumePointIsKeptWithUnfinishedParts() {
        var item = MediaItem(localIdentifier: nil, sha256: "h", filename: "a.mov", kind: .video, creationDate: nil, fileSize: 1)
        let file = RemoteFile(messageId: 1, fileId: "f", fileUniqueId: "u", size: 1000)
        let point = FileCrypto.ResumePoint(cipherOffset: 1000, chunkSize: 100, fileSalt: Data(repeating: 1, count: 16),
                                           nonce: nil, plaintextHash: "h")
        item.setParts([file], role: "o", expected: 3, resume: point)
        #expect(item.uploadResume?["o"] == point)
        item.setParts([], role: "o", expected: 3)
        #expect(item.uploadResume == nil)
        item.setParts([file], role: "o", expected: 3, resume: point)
        item.setParts([file, file, file], role: "o", expected: 3, resume: point)
        #expect(item.uploadResume == nil)
    }

    private func readAll(_ encryptor: FileCrypto.Encryptor) throws -> Data {
        var out = Data()
        while true {
            let bytes = try encryptor.read(upToCount: 333)
            if bytes.isEmpty { return out }
            out.append(bytes)
        }
    }
}
