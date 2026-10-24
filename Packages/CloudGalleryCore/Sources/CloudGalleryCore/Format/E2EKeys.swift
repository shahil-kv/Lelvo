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

/// The library header (docs/CLOUD_FORMAT.md §1).
public struct LibraryHeader: Equatable, Sendable {
    public static let messagePrefix = "#cloudgallery-library "

    public var encrypted: Bool
    public var iterations: UInt32
    public var salt: Data
    public var keyCheck: Data

    public static let plain = LibraryHeader(encrypted: false, iterations: 0, salt: Data(), keyCheck: Data())

    public init(encrypted: Bool, iterations: UInt32, salt: Data, keyCheck: Data) {
        self.encrypted = encrypted
        self.iterations = iterations
        self.salt = salt
        self.keyCheck = keyCheck
    }

    public var line: String {
        guard encrypted else { return "cg:1" }
        return "cg:1;e2e:1;it:\(iterations);s:\(salt.base64EncodedString());kc:\(keyCheck.base64EncodedString())"
    }

    public var messageText: String { Self.messagePrefix + line }

    /// Parses a header from a pinned message text or a channel description (any line starting with `cg:1`).
    public static func parse(_ text: String) -> LibraryHeader? {
        let tag = messagePrefix.trimmingCharacters(in: .whitespaces)
        let candidate = text.components(separatedBy: .newlines)
            .map { line -> String in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix(tag) ? String(trimmed.dropFirst(tag.count)).trimmingCharacters(in: .whitespaces) : trimmed
            }
            .first { $0.hasPrefix("cg:1") }
        guard let line = candidate else { return nil }
        var fields: [String: String] = [:]
        for pair in line.split(separator: ";") {
            let kv = pair.split(separator: ":", maxSplits: 1).map(String.init)
            if kv.count == 2 { fields[kv[0]] = kv[1] }
        }
        guard fields["cg"] == "1" else { return nil }
        guard fields["e2e"] == "1" else { return .plain }
        guard let it = fields["it"].flatMap(UInt32.init), it >= E2EKeys.minimumIterations,
              let salt = fields["s"].flatMap({ Data(base64Encoded: $0) }), salt.count == 16,
              let kc = fields["kc"].flatMap({ Data(base64Encoded: $0) }), kc.count == 16 else { return nil }
        return LibraryHeader(encrypted: true, iterations: it, salt: salt, keyCheck: kc)
    }

    public static func newEncrypted(passphrase: String, iterations: UInt32 = E2EKeys.defaultIterations) throws -> (LibraryHeader, E2EKeys) {
        let salt = KeyDerivation.randomSalt()
        let keys = try E2EKeys.derive(passphrase: passphrase, salt: salt, iterations: iterations)
        return (LibraryHeader(encrypted: true, iterations: iterations, salt: salt, keyCheck: keys.keyCheck), keys)
    }

    /// Derives keys and verifies the key check. Returns nil for a wrong passphrase.
    public func unlock(passphrase: String) throws -> E2EKeys? {
        let keys = try E2EKeys.derive(passphrase: passphrase, salt: salt, iterations: iterations)
        return keys.keyCheck == keyCheck ? keys : nil
    }
}
