import Foundation
import CryptoKit
import Testing
import CloudGalleryCore

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
