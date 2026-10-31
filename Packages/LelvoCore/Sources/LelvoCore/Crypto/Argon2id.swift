import Foundation
import CArgon2

/// Argon2id (RFC 9106), the memory-hard key derivation used for passphrases since format 2 (docs/CLOUD_FORMAT.md
/// §6.1). Guessing a passphrase costs an attacker the same memory per guess as it costs the app once, which graphics
/// cards can't do cheaply the way they can with PBKDF2.
public enum Argon2id {
    public struct Parameters: Equatable, Sendable {
        /// Passes over memory.
        public var iterations: UInt32
        /// Memory in KiB.
        public var memoryKiB: UInt32
        public var parallelism: UInt32 = 1

        public init(iterations: UInt32, memoryKiB: UInt32, parallelism: UInt32 = 1) {
            self.iterations = iterations
            self.memoryKiB = memoryKiB
            self.parallelism = parallelism
        }

        /// New libraries: 256 MiB, 3 passes (libsodium's MODERATE); well under a second on recent iPhones and Macs.
        public static let standard = Parameters(iterations: 3, memoryKiB: 256 * 1024)
        /// Readers refuse less than this (the OWASP minimum is 19 MiB with 2 passes).
        public static let minimumMemoryKiB: UInt32 = 19 * 1024
    }

    public static func derive(passphrase: String, salt: Data, parameters: Parameters, length: Int = 32) throws -> Data {
        let password = Array(passphrase.precomposedStringWithCanonicalMapping.utf8)
        return try derive(password: password, salt: salt, parameters: parameters, length: length)
    }

    static func derive(password: [UInt8], salt: Data, parameters p: Parameters, length: Int) throws -> Data {
        guard !password.isEmpty, salt.count >= 8, p.memoryKiB >= 8 * p.parallelism else { throw CryptoError.derivationFailed }
        var out = [UInt8](repeating: 0, count: length)
        let status = salt.withUnsafeBytes { s in
            password.withUnsafeBytes { pw in
                argon2id_hash_raw(p.iterations, p.memoryKiB, p.parallelism, pw.baseAddress, password.count,
                                  s.baseAddress, salt.count, &out, length)
            }
        }
        guard status == ARGON2_OK.rawValue else { throw CryptoError.derivationFailed }
        return Data(out)
    }
}
