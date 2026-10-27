import Foundation
import Testing
@testable import MemvoCore

/// Known answers from the reference implementation's own test suite (phc-winner-argon2 src/test.c, Argon2id, v19,
/// 32-byte output). `m` there is a power of two in KiB.
@Suite struct Argon2Tests {
    func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    func derive(_ pwd: String, _ salt: String, t: UInt32, mLog2: UInt32, p: UInt32 = 1) throws -> String {
        hex(try Argon2id.derive(password: Array(pwd.utf8), salt: Data(salt.utf8),
                                parameters: .init(iterations: t, memoryKiB: 1 << mLog2, parallelism: p), length: 32))
    }

    @Test func referenceVectors() throws {
        #expect(try derive("password", "somesalt", t: 2, mLog2: 16) == "09316115d5cf24ed5a15a31a3ba326e5cf32edc24702987c02b6566f61913cf7")
        #expect(try derive("password", "somesalt", t: 2, mLog2: 8) == "9dfeb910e80bad0311fee20f9c0e2b12c17987b4cac90c2ef54d5b3021c68bfe")
        #expect(try derive("password", "somesalt", t: 2, mLog2: 8, p: 2) == "6d093c501fd5999645e0ea3bf620d7b8be7fd2db59c20d9fff9539da2bf57037")
        #expect(try derive("password", "somesalt", t: 1, mLog2: 16) == "f6a5adc1ba723dddef9b5ac1d464e180fcd9dffc9d1cbf76cca2fed795d9ca98")
        #expect(try derive("password", "somesalt", t: 4, mLog2: 16) == "9025d48e68ef7395cca9079da4c4ec3affb3c8911fe4f86d1a2520856f63172c")
        #expect(try derive("differentpassword", "somesalt", t: 2, mLog2: 16) == "0b84d652cf6b0c4beaef0dfe278ba6a80df6696281d7e0d2891b817d8c458fde")
        #expect(try derive("password", "diffsalt", t: 2, mLog2: 16) == "bdf32b05ccc42eb15d58fd19b1f856b113da1e9a5874fdcc544308565aa8141c")
    }

    @Test func passphraseIsNormalised() throws {
        // "é" as one code point and as e + combining accent derive the same key (NFC, docs/CLOUD_FORMAT.md).
        let params = Argon2id.Parameters(iterations: 1, memoryKiB: 1024)
        let salt = Data(repeating: 7, count: 16)
        #expect(try Argon2id.derive(passphrase: "caf\u{e9}", salt: salt, parameters: params)
                == Argon2id.derive(passphrase: "cafe\u{301}", salt: salt, parameters: params))
    }

    @Test func refusesNonsense() {
        #expect(throws: CryptoError.derivationFailed) { try Argon2id.derive(passphrase: "", salt: Data(count: 16), parameters: .standard) }
        #expect(throws: CryptoError.derivationFailed) { try Argon2id.derive(passphrase: "x", salt: Data(count: 4), parameters: .standard) }
    }
}
