import Foundation
import CryptoKit
import CommonCrypto

public enum CryptoError: Error, Equatable, LocalizedError {
    case badFormat
    case unsupportedVersion(UInt8)
    case wrongPassphraseOrCorrupt
    case derivationFailed
    case truncated

    public var errorDescription: String? {
        switch self {
        case .badFormat: return "This file is not a CloudGallery encrypted file."
        case .unsupportedVersion(let v): return "Unsupported encrypted file version \(v). Update the app."
        case .wrongPassphraseOrCorrupt: return "Wrong passphrase, or the file is damaged."
        case .derivationFailed: return "Could not derive the encryption key."
        case .truncated: return "The encrypted file is incomplete."
        }
    }
}

public enum KeyDerivation {
    /// PBKDF2 work factor; OWASP recommends at least 210k iterations for HMAC-SHA256.
    public static let defaultIterations: UInt32 = 250_000
    public static let minimumIterations: UInt32 = 200_000
    public static let saltLength = 16

    public static func randomSalt(count: Int = saltLength) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes)
    }

    /// PBKDF2-HMAC-SHA256 → 256-bit key.
    public static func pbkdf2(passphrase: String, salt: Data, iterations: UInt32 = defaultIterations,
                              keyLength: Int = 32) throws -> Data {
        let password = Array(passphrase.precomposedStringWithCanonicalMapping.utf8)
        guard !password.isEmpty, !salt.isEmpty else { throw CryptoError.derivationFailed }
        var derived = [UInt8](repeating: 0, count: keyLength)
        let status = salt.withUnsafeBytes { saltPtr -> Int32 in
            password.withUnsafeBufferPointer { pwPtr in
                pwPtr.baseAddress!.withMemoryRebound(to: Int8.self, capacity: password.count) { pw in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw, password.count,
                                         saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                                         &derived, keyLength)
                }
            }
        }
        guard status == kCCSuccess else { throw CryptoError.derivationFailed }
        return Data(derived)
    }

    public static func symmetricKey(passphrase: String, salt: Data, iterations: UInt32 = defaultIterations) throws -> SymmetricKey {
        SymmetricKey(data: try pbkdf2(passphrase: passphrase, salt: salt, iterations: iterations))
    }
}
