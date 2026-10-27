import Foundation
import CryptoKit

/// Key material for end-to-end encrypted libraries (docs/CLOUD_FORMAT.md §6).
public struct E2EKeys: Sendable {
    public static let defaultIterations: UInt32 = 600_000
    public static let minimumIterations: UInt32 = 100_000

    public let master: SymmetricKey
    public var captionKey: SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: Data(count: 32),
                               info: Data("CloudGallery caption v1".utf8), outputByteCount: 32)
    }

    public init(master: SymmetricKey) { self.master = master }

    public static func derive(passphrase: String, salt: Data, iterations: UInt32 = defaultIterations) throws -> E2EKeys {
        E2EKeys(master: SymmetricKey(data: try KeyDerivation.pbkdf2(passphrase: passphrase, salt: salt, iterations: iterations)))
    }

    /// First 16 bytes of HMAC-SHA256(master, "CloudGallery key check v1").
    public var keyCheck: Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("CloudGallery key check v1".utf8), using: master).prefix(16))
    }

    public var masterData: Data { master.withUnsafeBytes { Data($0) } }

    static func sealCaption(_ json: Data, key: SymmetricKey, nonce: AES.GCM.Nonce = AES.GCM.Nonce()) throws -> Data {
        let box = try AES.GCM.seal(json, using: key, nonce: nonce, authenticating: Data("CG1E".utf8))
        guard let combined = box.combined else { throw CryptoError.badFormat }
        return combined
    }

    static func openCaption(_ blob: Data, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: blob)
        return try AES.GCM.open(box, using: key, authenticating: Data("CG1E".utf8))
    }

    /// Deterministic-nonce variant, only for generating test vectors.
    public static func sealCaptionForTesting(_ json: Data, key: SymmetricKey, nonce: Data) throws -> Data {
        try sealCaption(json, key: key, nonce: try AES.GCM.Nonce(data: nonce))
    }
}

/// The library header (docs/CLOUD_FORMAT.md §1, §6.1).
///
/// Format 1 derives the master key straight from the passphrase (PBKDF2), so the passphrase can never change. Format 2
/// keeps a master key that is only stored locked: once with a key from the passphrase (Argon2id) and once with a
/// recovery key. Changing the passphrase rewrites the small locked copy; files and captions never change. A format 1
/// library is upgraded by locking the master key it already has.
public struct LibraryHeader: Equatable, Sendable {
    public static let messagePrefix = "#cloudgallery-library "
    /// The newest header format this version reads.
    public static let supportedVersion = 2

    public var version: Int
    public var encrypted: Bool
    /// Format 1: PBKDF2 iterations and the key check.
    public var iterations: UInt32
    public var keyCheck: Data
    /// Format 1: PBKDF2 salt. Format 2: Argon2id salt.
    public var salt: Data
    /// Format 2: Argon2id cost.
    public var argon: Argon2id.Parameters?
    /// Format 2: the master key locked with the passphrase key, and with the recovery key (AES-GCM, nonce ‖ ct ‖ tag).
    public var lockedByPassphrase: Data?
    public var lockedByRecoveryKey: Data?
    /// The channel was set up by a newer Memvo: don't read, write or "repair" it.
    public var isNewerVersion = false

    public static let plain = LibraryHeader(encrypted: false, iterations: 0, salt: Data(), keyCheck: Data())

    /// A format 1 header.
    public init(encrypted: Bool, iterations: UInt32, salt: Data, keyCheck: Data) {
        self.version = 1
        self.encrypted = encrypted
        self.iterations = iterations
        self.salt = salt
        self.keyCheck = keyCheck
    }

    init(argon: Argon2id.Parameters, salt: Data, lockedByPassphrase: Data, lockedByRecoveryKey: Data) {
        self.version = 2
        self.encrypted = true
        self.iterations = 0
        self.keyCheck = Data()
        self.salt = salt
        self.argon = argon
        self.lockedByPassphrase = lockedByPassphrase
        self.lockedByRecoveryKey = lockedByRecoveryKey
    }

    static func newer(version: Int) -> LibraryHeader {
        var h = LibraryHeader.plain
        h.version = version
        h.isNewerVersion = true
        return h
    }

    public var line: String {
        guard encrypted else { return "cg:1" }
        guard version == 2, let argon, let lockedByPassphrase, let lockedByRecoveryKey else {
            return "cg:1;e2e:1;it:\(iterations);s:\(salt.base64EncodedString());kc:\(keyCheck.base64EncodedString())"
        }
        return "cg:2;e2e:1;a2:\(argon.iterations),\(argon.memoryKiB),\(argon.parallelism);s:\(salt.base64EncodedString())"
            + ";wk:\(lockedByPassphrase.base64EncodedString());rk:\(lockedByRecoveryKey.base64EncodedString())"
    }

    /// The pinned header message. A format 2 header also carries a format 1 line with random values: versions before
    /// format 2 read that one, ask for the passphrase and always find it wrong, instead of taking the channel for one
    /// without a header and adding a plain header (and unencrypted uploads) to an encrypted library.
    public var messageText: String {
        guard version == 2 else { return Self.messagePrefix + line }
        let decoy = LibraryHeader(encrypted: true, iterations: E2EKeys.defaultIterations,
                                  salt: KeyDerivation.randomSalt(), keyCheck: KeyDerivation.randomSalt())
        return Self.messagePrefix + line + "\n" + Self.messagePrefix + decoy.line
    }

    /// Parses a header from a pinned message text or a channel description. Of several header lines the newest
    /// supported one wins; any line from a newer format makes the header `isNewerVersion`.
    public static func parse(_ text: String) -> LibraryHeader? {
        let tag = messagePrefix.trimmingCharacters(in: .whitespaces)
        let lines = text.components(separatedBy: .newlines)
            .map { line -> String in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix(tag) ? String(trimmed.dropFirst(tag.count)).trimmingCharacters(in: .whitespaces) : trimmed
            }
            .filter { $0.hasPrefix("cg:") }
        var best: LibraryHeader?
        for line in lines {
            var fields: [String: String] = [:]
            for pair in line.split(separator: ";") {
                let kv = pair.split(separator: ":", maxSplits: 1).map(String.init)
                if kv.count == 2 { fields[kv[0]] = kv[1] }
            }
            guard let version = fields["cg"].flatMap(Int.init) else { continue }
            if version > supportedVersion { return .newer(version: version) }
            guard let header = version == 2 ? parseVersion2(fields) : parseVersion1(fields) else { continue }
            if (best?.version ?? 0) < header.version { best = header }
        }
        return best
    }

    private static func parseVersion1(_ fields: [String: String]) -> LibraryHeader? {
        guard fields["e2e"] == "1" else { return .plain }
        guard let it = fields["it"].flatMap(UInt32.init), it >= E2EKeys.minimumIterations,
              let salt = fields["s"].flatMap({ Data(base64Encoded: $0) }), salt.count == 16,
              let kc = fields["kc"].flatMap({ Data(base64Encoded: $0) }), kc.count == 16 else { return nil }
        return LibraryHeader(encrypted: true, iterations: it, salt: salt, keyCheck: kc)
    }

    private static func parseVersion2(_ fields: [String: String]) -> LibraryHeader? {
        guard fields["e2e"] == "1" else { return nil }
        let cost = (fields["a2"] ?? "").split(separator: ",").compactMap { UInt32($0) }
        guard cost.count == 3, cost[0] >= 1, cost[1] >= Argon2id.Parameters.minimumMemoryKiB, (1...16).contains(cost[2]),
              let salt = fields["s"].flatMap({ Data(base64Encoded: $0) }), salt.count == 16,
              let wk = fields["wk"].flatMap({ Data(base64Encoded: $0) }), wk.count == MasterKeyLock.sealedLength,
              let rk = fields["rk"].flatMap({ Data(base64Encoded: $0) }), rk.count == MasterKeyLock.sealedLength else { return nil }
        return LibraryHeader(argon: .init(iterations: cost[0], memoryKiB: cost[1], parallelism: cost[2]),
                             salt: salt, lockedByPassphrase: wk, lockedByRecoveryKey: rk)
    }

    /// A format 1 header for new libraries in tests and test vectors only; new libraries use `newLibrary`.
    public static func newEncrypted(passphrase: String, iterations: UInt32 = E2EKeys.defaultIterations) throws -> (LibraryHeader, E2EKeys) {
        let salt = KeyDerivation.randomSalt()
        let keys = try E2EKeys.derive(passphrase: passphrase, salt: salt, iterations: iterations)
        return (LibraryHeader(encrypted: true, iterations: iterations, salt: salt, keyCheck: keys.keyCheck), keys)
    }

    /// A new encrypted library: a random master key, locked with the passphrase and a new recovery key.
    public static func newLibrary(passphrase: String, argon: Argon2id.Parameters = .standard) throws -> (LibraryHeader, E2EKeys, RecoveryKey) {
        let keys = E2EKeys(master: SymmetricKey(size: .bits256))
        let (header, recovery) = try locking(keys, passphrase: passphrase, argon: argon)
        return (header, keys, recovery)
    }

    /// Format 2 for the master key a library already has (upgrading format 1, or a new recovery key): the files and
    /// captions stay as they are.
    public static func locking(_ keys: E2EKeys, passphrase: String, recoveryKey: RecoveryKey = .random(),
                               argon: Argon2id.Parameters = .standard) throws -> (LibraryHeader, RecoveryKey) {
        let salt = KeyDerivation.randomSalt()
        let passphraseKey = SymmetricKey(data: try Argon2id.derive(passphrase: passphrase, salt: salt, parameters: argon))
        let header = LibraryHeader(argon: argon, salt: salt,
                                   lockedByPassphrase: try MasterKeyLock.seal(keys.master, with: passphraseKey, purpose: .passphrase),
                                   lockedByRecoveryKey: try MasterKeyLock.seal(keys.master, with: recoveryKey.lockKey, purpose: .recovery))
        return (header, recoveryKey)
    }

    /// The same library with a new passphrase; the recovery key keeps working.
    public func changingPassphrase(_ keys: E2EKeys, to passphrase: String) throws -> LibraryHeader {
        guard version == 2, let argon, let lockedByRecoveryKey else { throw CryptoError.badFormat }
        let salt = KeyDerivation.randomSalt()
        let passphraseKey = SymmetricKey(data: try Argon2id.derive(passphrase: passphrase, salt: salt, parameters: argon))
        return LibraryHeader(argon: argon, salt: salt,
                             lockedByPassphrase: try MasterKeyLock.seal(keys.master, with: passphraseKey, purpose: .passphrase),
                             lockedByRecoveryKey: lockedByRecoveryKey)
    }

    /// The same library with a new recovery key (the old one stops working); the passphrase keeps working.
    public func replacingRecoveryKey(_ keys: E2EKeys) throws -> (LibraryHeader, RecoveryKey) {
        guard version == 2, let argon, let lockedByPassphrase else { throw CryptoError.badFormat }
        let recovery = RecoveryKey.random()
        let header = LibraryHeader(argon: argon, salt: salt, lockedByPassphrase: lockedByPassphrase,
                                   lockedByRecoveryKey: try MasterKeyLock.seal(keys.master, with: recovery.lockKey, purpose: .recovery))
        return (header, recovery)
    }

    /// The keys for this passphrase, or nil when it's wrong.
    public func unlock(passphrase: String) throws -> E2EKeys? {
        if version == 2 {
            guard let argon, let lockedByPassphrase else { return nil }
            let key = SymmetricKey(data: try Argon2id.derive(passphrase: passphrase, salt: salt, parameters: argon))
            return MasterKeyLock.open(lockedByPassphrase, with: key, purpose: .passphrase).map(E2EKeys.init(master:))
        }
        let keys = try E2EKeys.derive(passphrase: passphrase, salt: salt, iterations: iterations)
        return keys.keyCheck == keyCheck ? keys : nil
    }

    /// The keys for this recovery key, or nil when it doesn't belong to this library (format 2 only).
    public func unlock(recoveryKey: RecoveryKey) -> E2EKeys? {
        guard version == 2, let lockedByRecoveryKey else { return nil }
        return MasterKeyLock.open(lockedByRecoveryKey, with: recoveryKey.lockKey, purpose: .recovery).map(E2EKeys.init(master:))
    }
}

/// The master key, locked with AES-256-GCM. The purpose is authenticated, so a passphrase-locked copy can't be passed
/// off as the recovery copy or the other way round.
enum MasterKeyLock {
    enum Purpose: String { case passphrase, recovery }
    /// nonce (12) ‖ ciphertext (32) ‖ tag (16).
    static let sealedLength = 60

    static func aad(_ purpose: Purpose) -> Data { Data("Memvo master key v2 \(purpose.rawValue)".utf8) }

    static func seal(_ master: SymmetricKey, with key: SymmetricKey, purpose: Purpose, nonce: AES.GCM.Nonce = AES.GCM.Nonce()) throws -> Data {
        let plain = master.withUnsafeBytes { Data($0) }
        guard let combined = try AES.GCM.seal(plain, using: key, nonce: nonce, authenticating: aad(purpose)).combined else {
            throw CryptoError.badFormat
        }
        return combined
    }

    static func open(_ sealed: Data, with key: SymmetricKey, purpose: Purpose) -> SymmetricKey? {
        guard let box = try? AES.GCM.SealedBox(combined: sealed),
              let plain = try? AES.GCM.open(box, using: key, authenticating: aad(purpose)), plain.count == 32 else { return nil }
        return SymmetricKey(data: plain)
    }
}

/// A recovery key: 32 random bytes the user writes down, shown as 13 groups of 4 letters and digits
/// (RFC 4648 base32 without padding). It opens the library when the passphrase is forgotten.
public struct RecoveryKey: Equatable, Sendable {
    public let bytes: Data
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    public init?(bytes: Data) {
        guard bytes.count == 32 else { return nil }
        self.bytes = bytes
    }

    public static func random() -> RecoveryKey { RecoveryKey(bytes: KeyDerivation.randomSalt(count: 32))! }

    /// The key that locks the master key's recovery copy.
    var lockKey: SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: bytes), salt: Data(count: 32),
                               info: Data("Memvo recovery key v2".utf8), outputByteCount: 32)
    }

    /// "ABCD-EFGH-…", 13 groups.
    public var text: String {
        var bits = 0, value = 0, out: [Character] = []
        for byte in bytes {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                out.append(Self.alphabet[(value >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { out.append(Self.alphabet[(value << (5 - bits)) & 31]) }
        return stride(from: 0, to: out.count, by: 4).map { String(out[$0..<min($0 + 4, out.count)]) }.joined(separator: "-")
    }

    /// Reads a typed or pasted key: case, spaces and dashes don't matter, and the digits 0, 1 and 8 count as the
    /// letters O, I and B they're easily mistaken for.
    public init?(text: String) {
        let cleaned = text.uppercased().compactMap { c -> Character? in
            switch c {
            case "0": return "O"
            case "1": return "I"
            case "8": return "B"
            case " ", "-", "\n", "\t": return nil
            default: return c
            }
        }
        guard cleaned.count == 52 else { return nil }
        var bits = 0, value = 0, bytes: [UInt8] = []
        for c in cleaned {
            guard let index = Self.alphabet.firstIndex(of: c) else { return nil }
            value = (value << 5) | index
            bits += 5
            if bits >= 8 {
                bytes.append(UInt8((value >> (bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        self.init(bytes: Data(bytes.prefix(32)))
    }
}
