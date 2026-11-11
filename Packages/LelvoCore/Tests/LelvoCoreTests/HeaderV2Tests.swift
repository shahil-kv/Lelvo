import Foundation
import CryptoKit
import Testing
@testable import LelvoCore

@Suite struct HeaderV2Tests {
    /// The smallest cost readers accept, so the tests stay quick.
    let cheap = Argon2id.Parameters(iterations: 1, memoryKiB: Argon2id.Parameters.minimumMemoryKiB)

    func master(_ keys: E2EKeys) -> Data { keys.masterData }

    @Test func newLibraryOpensWithPassphraseOrRecoveryKey() throws {
        let (header, keys, recovery) = try LibraryHeader.newLibrary(passphrase: "correct horse", argon: cheap)
        #expect(header.version == 2)
        #expect(try header.unlock(passphrase: "correct horse").map(master) == master(keys))
        #expect(try header.unlock(passphrase: "wrong horse") == nil)
        #expect(header.unlock(recoveryKey: recovery).map(master) == master(keys))
        #expect(header.unlock(recoveryKey: .random()) == nil)
    }

    @Test func changingThePassphraseKeepsTheKeyAndTheRecoveryKey() throws {
        let (header, keys, recovery) = try LibraryHeader.newLibrary(passphrase: "old", argon: cheap)
        let changed = try header.changingPassphrase(keys, to: "new")
        #expect(try changed.unlock(passphrase: "old") == nil)
        #expect(try changed.unlock(passphrase: "new").map(master) == master(keys))
        #expect(changed.unlock(recoveryKey: recovery).map(master) == master(keys))
    }

    @Test func aNewRecoveryKeyReplacesTheOldOne() throws {
        let (header, keys, old) = try LibraryHeader.newLibrary(passphrase: "pw", argon: cheap)
        let (replaced, new) = try header.replacingRecoveryKey(keys)
        #expect(replaced.unlock(recoveryKey: old) == nil)
        #expect(replaced.unlock(recoveryKey: new).map(master) == master(keys))
        #expect(try replaced.unlock(passphrase: "pw").map(master) == master(keys))
    }

    /// A header edited to ask for an extreme cost is refused before any work, and still counts as encrypted.
    @Test func unlockingRefusesACostBeyondTheLimits() throws {
        var (header, _, _) = try LibraryHeader.newLibrary(passphrase: "pw", argon: cheap)
        header.argon = Argon2id.Parameters(iterations: 1, memoryKiB: Argon2id.Parameters.maximumMemoryKiB + 1)
        #expect(throws: CryptoError.derivationFailed) { try header.unlock(passphrase: "pw") }
        header.argon = Argon2id.Parameters(iterations: Argon2id.Parameters.maximumIterations + 1, memoryKiB: cheap.memoryKiB)
        #expect(throws: CryptoError.derivationFailed) { try header.unlock(passphrase: "pw") }
        #expect(LibraryHeader.parse(header.messageText)?.encrypted == true)
        #expect(Argon2id.Parameters.standard.isWithinLimits)

        var v1 = LibraryHeader(encrypted: true, iterations: UInt32.max, salt: KeyDerivation.randomSalt(),
                               keyCheck: KeyDerivation.randomSalt())
        #expect(throws: CryptoError.derivationFailed) { try v1.unlock(passphrase: "pw") }
        v1.iterations = E2EKeys.defaultIterations
        #expect(try v1.unlock(passphrase: "pw") == nil) // in range: just the wrong passphrase
    }

    /// Upgrading keeps the master key, so every file and caption written under format 1 still opens.
    @Test func upgradingFormat1KeepsEverythingReadable() throws {
        let (v1, keys) = try LibraryHeader.newEncrypted(passphrase: "pw", iterations: E2EKeys.minimumIterations)
        var meta = CaptionMeta(id: "0b7c0e3e-6f1e-4c55-9a33-1f3f0c0a9d10", role: .original, kind: .photo,
                               sha256: String(repeating: "a", count: 64), name: "IMG_1.HEIC", size: 1)
        meta.e = 1
        let caption = try CaptionCodec.encode(meta, captionKey: keys.captionKey)
        let file = try FileCrypto.encrypt(data: Data("photo bytes".utf8), masterKey: keys.master)

        let (v2, recovery) = try LibraryHeader.locking(try #require(try v1.unlock(passphrase: "pw")), passphrase: "pw", argon: cheap)
        let reopened = try #require(try v2.unlock(passphrase: "pw"))
        #expect(try CaptionCodec.decode(caption, captionKey: reopened.captionKey).id == meta.id)
        #expect(try FileCrypto.decrypt(data: file, masterKey: reopened.master) == Data("photo bytes".utf8))
        #expect(v2.unlock(recoveryKey: recovery).map(master) == master(keys))
        #expect(v2.salt != v1.salt)
        #expect(!v2.line.contains("kc:"))
    }

    @Test func pinnedMessageRoundTripsAndOlderVersionsCantOpenIt() throws {
        let (header, _, _) = try LibraryHeader.newLibrary(passphrase: "pw", argon: cheap)
        #expect(LibraryHeader.parse(header.messageText) == header)
        // What a format 1 reader sees: only the cg:1 line, with random values, so the passphrase never matches.
        let decoy = try #require(header.messageText.components(separatedBy: "\n").first { $0.contains("cg:1") })
        let seenByOldReader = try #require(LibraryHeader.parse(decoy))
        #expect(seenByOldReader.version == 1 && seenByOldReader.encrypted)
        #expect(try seenByOldReader.unlock(passphrase: "pw") == nil)
        // The description holds the format 2 line alone and must fit Telegram's 255 characters with its label.
        #expect(("Lelvo Library · do not edit\n" + header.line).count <= 255)
    }

    @Test func aNewerFormatIsNeverTakenForAMissingHeader() {
        #expect(LibraryHeader.parse("#cloudgallery-library cg:3;e2e:1;x:y")?.isNewerVersion == true)
        #expect(LibraryHeader.parse("#cloudgallery-library cg:3;zz\n#cloudgallery-library cg:1")?.isNewerVersion == true)
        #expect(LibraryHeader.parse("cg:1")?.isNewerVersion == false)
    }

    @Test func lockedCopiesCantBeSwapped() throws {
        let (header, _, _) = try LibraryHeader.newLibrary(passphrase: "pw", argon: cheap)
        var swapped = header
        swapped.lockedByPassphrase = header.lockedByRecoveryKey
        #expect(try swapped.unlock(passphrase: "pw") == nil)
    }

    @Test func weakOrDamagedHeadersAreRefused() throws {
        let (header, _, _) = try LibraryHeader.newLibrary(passphrase: "pw", argon: cheap)
        let weak = header.line.replacingOccurrences(of: "a2:1,\(cheap.memoryKiB),1", with: "a2:1,1024,1")
        #expect(LibraryHeader.parse(weak) == nil)
        let cut = String(header.line.dropLast(10))
        #expect(LibraryHeader.parse(cut) == nil)
    }

    @Test func recoveryKeyTextRoundTripsAndForgivesTypos() throws {
        let key = RecoveryKey.random()
        #expect(key.text.count == 52 + 12)
        #expect(RecoveryKey(text: key.text) == key)
        #expect(RecoveryKey(text: key.text.lowercased().replacingOccurrences(of: "-", with: " ")) == key)
        let withDigits = key.text.replacingOccurrences(of: "O", with: "0").replacingOccurrences(of: "I", with: "1")
        #expect(RecoveryKey(text: withDigits) == key)
        #expect(RecoveryKey(text: "ABCD-EFGH") == nil)
        #expect(RecoveryKey(text: String(repeating: "!", count: 52)) == nil)
    }
}

/// Cross-platform vector in docs/test-vectors/format2-header.json: other readers must get identical results.
@Suite struct HeaderV2VectorTests {
    struct Vector: Decodable {
        let passphrase: String
        let argon2idIterations: UInt32, argon2idMemoryKiB: UInt32, argon2idParallelism: UInt32
        let saltHex, passphraseKeyHex, masterHex, recoveryKey, recoveryLockKeyHex, passphraseNonceHex, recoveryNonceHex, header: String
    }

    static let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/test-vectors/format2-header.json")

    func bytes(_ hex: String) -> Data {
        Data(stride(from: 0, to: hex.count, by: 2).map { UInt8(hex.dropFirst($0).prefix(2), radix: 16)! })
    }
    func hex(_ k: SymmetricKey) -> String { k.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined() }

    @Test func matchesTheCommittedVector() throws {
        let v = try JSONDecoder().decode(Vector.self, from: Data(contentsOf: Self.url))
        let argon = Argon2id.Parameters(iterations: v.argon2idIterations, memoryKiB: v.argon2idMemoryKiB, parallelism: v.argon2idParallelism)
        let passphraseKey = SymmetricKey(data: try Argon2id.derive(passphrase: v.passphrase, salt: bytes(v.saltHex), parameters: argon))
        #expect(hex(passphraseKey) == v.passphraseKeyHex)
        let recovery = try #require(RecoveryKey(text: v.recoveryKey))
        #expect(hex(recovery.lockKey) == v.recoveryLockKeyHex)
        let master = SymmetricKey(data: bytes(v.masterHex))
        let rebuilt = LibraryHeader(argon: argon, salt: bytes(v.saltHex),
                                    lockedByPassphrase: try MasterKeyLock.seal(master, with: passphraseKey, purpose: .passphrase,
                                                                               nonce: try AES.GCM.Nonce(data: bytes(v.passphraseNonceHex))),
                                    lockedByRecoveryKey: try MasterKeyLock.seal(master, with: recovery.lockKey, purpose: .recovery,
                                                                                nonce: try AES.GCM.Nonce(data: bytes(v.recoveryNonceHex))))
        #expect(rebuilt.line == v.header)
        let header = try #require(LibraryHeader.parse(v.header))
        #expect(try header.unlock(passphrase: v.passphrase).map(\.masterData) == bytes(v.masterHex))
        #expect(header.unlock(recoveryKey: recovery).map(\.masterData) == bytes(v.masterHex))
    }
}

/// The same passphrase typed with an iPhone's Smart Punctuation, on a Mac, or with stray spaces opens the library.
@Suite struct PassphraseNormalizationTests {
    let cheap = Argon2id.Parameters(iterations: 1, memoryKiB: Argon2id.Parameters.minimumMemoryKiB)

    @Test func smartPunctuationGoesBackToTheTypedKeys() {
        #expect(Passphrase.normalized("don\u{2019}t \u{201C}panic\u{201D} \u{2014} ok\u{2026}") == "don't \"panic\" -- ok...")
        // Spaces are kept: what older versions use, byte for byte.
        #expect(Passphrase.normalized("  spaced out \n") == "  spaced out \n")
        #expect(Passphrase.normalized("plain ascii-only") == "plain ascii-only")
        #expect(Passphrase.candidates("plain") == ["plain"])
        #expect(Passphrase.candidates(" x\u{2019}y") == [" x\u{2019}y", " x'y", "x'y"])
    }

    @Test func aLibraryMadeOnTheIPhoneOpensOnTheMac() throws {
        // Set with Show on (Smart Punctuation), unlocked on a Mac with plain keys, and with Show off.
        let (header, keys, _) = try LibraryHeader.newLibrary(passphrase: "my dog\u{2019}s name \u{2014} rex", argon: cheap)
        #expect(try header.unlock(passphrase: "my dog's name -- rex")?.masterData == keys.masterData)
        #expect(try header.unlock(passphrase: "my dog\u{2019}s name \u{2014} rex")?.masterData == keys.masterData)
        #expect(try header.unlock(passphrase: "my dog's name -- rex ")?.masterData == keys.masterData)
        #expect(try header.unlock(passphrase: "my dogs name rex") == nil)
    }

    @Test func aLibraryMadeOnTheMacOpensOnTheIPhone() throws {
        let (header, keys, _) = try LibraryHeader.newLibrary(passphrase: "it's -- fine", argon: cheap)
        #expect(try header.unlock(passphrase: "it\u{2019}s \u{2014} fine")?.masterData == keys.masterData)
    }

    @Test func aPassphraseWithoutSmartPunctuationIsUsedExactlyAsTyped() throws {
        // Older versions of Lelvo derive from the typed text with no changes; a new library must open there too.
        let typed = " spaces and plain 'quotes' "
        let (header, keys, _) = try LibraryHeader.newLibrary(passphrase: typed, argon: cheap)
        let key = SymmetricKey(data: try Argon2id.derive(passphrase: typed, salt: header.salt, parameters: cheap))
        #expect(MasterKeyLock.open(try #require(header.lockedByPassphrase), with: key, purpose: .passphrase)
            .map { E2EKeys(master: $0).masterData } == keys.masterData)
    }

    @Test func librariesLockedBeforeNormalizationStillOpen() throws {
        // Before this, the passphrase was used exactly as typed, smart quotes and spaces included.
        let keys = E2EKeys(master: SymmetricKey(size: .bits256))
        let salt = Data(repeating: 7, count: 16)
        let typed = " old\u{2019}one "
        let lockKey = SymmetricKey(data: try Argon2id.derive(passphrase: typed, salt: salt, parameters: cheap))
        let old = LibraryHeader(argon: cheap, salt: salt,
                                lockedByPassphrase: try MasterKeyLock.seal(keys.master, with: lockKey, purpose: .passphrase),
                                lockedByRecoveryKey: try MasterKeyLock.seal(keys.master, with: RecoveryKey.random().lockKey, purpose: .recovery))
        #expect(try old.unlock(passphrase: typed)?.masterData == keys.masterData)
        // A format 1 library, too.
        let (v1, v1Keys) = try LibraryHeader.newEncrypted(passphrase: typed, iterations: 1_000)
        #expect(try v1.unlock(passphrase: typed)?.masterData == v1Keys.masterData)
    }

    @Test func changingThePassphraseNormalizesTheNewOne() throws {
        let (header, keys, recovery) = try LibraryHeader.newLibrary(passphrase: "first one", argon: cheap)
        let changed = try header.changingPassphrase(keys, to: "second\u{2019}s")
        #expect(try changed.unlock(passphrase: "second's")?.masterData == keys.masterData)
        #expect(changed.unlock(recoveryKey: recovery)?.masterData == keys.masterData)
    }
}
