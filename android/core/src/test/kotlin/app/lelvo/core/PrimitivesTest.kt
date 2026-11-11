package app.lelvo.core

import app.lelvo.core.crypto.Argon2Parameters
import app.lelvo.core.crypto.CryptoException
import app.lelvo.core.crypto.Hkdf
import app.lelvo.core.crypto.KeyDerivation
import app.lelvo.core.crypto.derive
import java.text.Normalizer
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class PrimitivesTest {
    @Test
    fun hkdfMatchesRfc5869() {
        // Test case 1.
        val okm = Hkdf.sha256(unhex("0b".repeat(22)), unhex("000102030405060708090a0b0c"), unhex("f0f1f2f3f4f5f6f7f8f9"), 42)
        assertEquals("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865", hex(okm))
        // Test case 3: no salt, no info.
        val bare = Hkdf.sha256(unhex("0b".repeat(22)), ByteArray(0), ByteArray(0), 42)
        assertEquals("8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8", hex(bare))
    }

    @Test
    fun pbkdf2MatchesKnownVectors() {
        val salt = "salt".toByteArray()
        assertEquals("120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b", hex(KeyDerivation.pbkdf2("password", salt, 1)))
        assertEquals("ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43", hex(KeyDerivation.pbkdf2("password", salt, 2)))
        assertEquals("c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a", hex(KeyDerivation.pbkdf2("password", salt, 4096)))
    }

    /** PBKDF2 written out over HMAC with explicit UTF-8 bytes: what the iPhone computes. */
    private fun referencePbkdf2(password: ByteArray, salt: ByteArray, iterations: Int): ByteArray {
        val mac = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(password, "HmacSHA256")) }
        var u = mac.doFinal(salt + byteArrayOf(0, 0, 0, 1))
        val out = u.copyOf()
        repeat(iterations - 1) {
            u = mac.doFinal(u)
            for (i in out.indices) out[i] = (out[i].toInt() xor u[i].toInt()).toByte()
        }
        return out
    }

    @Test
    fun passphrasesBeyondAsciiAreUtf8InNfc() {
        val salt = "s".toByteArray()
        // Two-, three- and four-byte characters (the last is a surrogate pair in Kotlin).
        for (passphrase in listOf("café", "пароль", "密码", "key 🔑 ok")) {
            val expected = referencePbkdf2(Normalizer.normalize(passphrase, Normalizer.Form.NFC).toByteArray(Charsets.UTF_8), salt, 10)
            assertContentEquals(expected, KeyDerivation.pbkdf2(passphrase, salt, 10), passphrase)
        }
        // "é" precomposed and decomposed derive the same key.
        assertContentEquals(KeyDerivation.pbkdf2("café", salt, 10), KeyDerivation.pbkdf2("café", salt, 10))
    }

    @Test
    fun emptyPassphraseOrSaltIsRefused() {
        assertFailsWith<CryptoException.DerivationFailed> { KeyDerivation.pbkdf2("", byteArrayOf(1, 2, 3), 1) }
        assertFailsWith<CryptoException.DerivationFailed> { KeyDerivation.pbkdf2("x", ByteArray(0), 1) }
    }

    @Test
    fun argon2ReferenceVectors() {
        fun derive(password: String, salt: String, t: Int, mLog2: Int, p: Int = 1) =
            hex(testArgon2.hash(password.toByteArray(), salt.toByteArray(), t, 1 shl mLog2, p, 32))
        assertEquals("09316115d5cf24ed5a15a31a3ba326e5cf32edc24702987c02b6566f61913cf7", derive("password", "somesalt", 2, 16))
        assertEquals("9dfeb910e80bad0311fee20f9c0e2b12c17987b4cac90c2ef54d5b3021c68bfe", derive("password", "somesalt", 2, 8))
        assertEquals("6d093c501fd5999645e0ea3bf620d7b8be7fd2db59c20d9fff9539da2bf57037", derive("password", "somesalt", 2, 8, 2))
        assertEquals("bdf32b05ccc42eb15d58fd19b1f856b113da1e9a5874fdcc544308565aa8141c", derive("password", "diffsalt", 2, 16))
    }

    @Test
    fun argon2PassphraseIsNormalisedAndNonsenseRefused() {
        val salt = ByteArray(16) { 7 }
        assertContentEquals(testArgon2.derive("café", salt, cheapArgon), testArgon2.derive("café", salt, cheapArgon))
        assertFailsWith<CryptoException.DerivationFailed> { testArgon2.derive("", ByteArray(16), cheapArgon) }
        assertFailsWith<CryptoException.DerivationFailed> { testArgon2.derive("x", ByteArray(4), cheapArgon) }
        // Beyond the limits nothing is computed, whoever asks.
        assertFailsWith<CryptoException.DerivationFailed> { testArgon2.derive("x", salt, Argon2Parameters(1, 1024)) }
        assertFailsWith<CryptoException.DerivationFailed> { testArgon2.derive("x", salt, Argon2Parameters(11, 19456)) }
        assertFailsWith<CryptoException.DerivationFailed> { testArgon2.derive("x", salt, Argon2Parameters(1, 1024L * 1024 + 1)) }
        // An implementation that fails (out of memory on a small phone) is a failed derivation, not a crash.
        val broken = app.lelvo.core.crypto.Argon2id { _, _, _, _, _, _ -> throw IllegalStateException("no memory") }
        assertFailsWith<CryptoException.DerivationFailed> { broken.derive("x", salt, cheapArgon) }
        kotlin.test.assertTrue(Argon2Parameters.STANDARD.isWithinLimits)
    }
}
