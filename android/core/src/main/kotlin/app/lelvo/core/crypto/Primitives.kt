package app.lelvo.core.crypto

import java.security.GeneralSecurityException
import java.security.MessageDigest
import java.security.SecureRandom
import java.text.Normalizer
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

// This module also runs on Android 10 (API 29): only java.* calls that exist there. No HexFormat, no
// InputStream.readNBytes/readAllBytes/skipNBytes (API 33+), which compile fine on the JVM and crash on older phones.

/** "UTF-8" in the format always means NFC (docs/CLOUD_FORMAT.md, top). */
internal fun String.nfc(): String = Normalizer.normalize(this, Normalizer.Form.NFC)

object Hashing {
    fun sha256(data: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(data)

    /** Lowercase hex, as captions store `h`. */
    fun sha256Hex(data: ByteArray): String = Bytes.hex(sha256(data))
}

internal object Bytes {
    private val random = SecureRandom()
    private const val HEX = "0123456789abcdef"

    fun random(count: Int): ByteArray = ByteArray(count).also(random::nextBytes)

    fun hex(bytes: ByteArray): String {
        val out = StringBuilder(bytes.size * 2)
        for (b in bytes) {
            out.append(HEX[(b.toInt() shr 4) and 0xF]).append(HEX[b.toInt() and 0xF])
        }
        return out.toString()
    }

    fun base64(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)

    /** Standard Base64; null for anything else (line breaks, URL-safe letters), like the other readers. */
    fun base64OrNull(text: String): ByteArray? = try {
        Base64.getDecoder().decode(text)
    } catch (_: IllegalArgumentException) {
        null
    }

    fun u32be(value: Int): ByteArray = byteArrayOf((value ushr 24).toByte(), (value ushr 16).toByte(), (value ushr 8).toByte(), value.toByte())

    fun u64be(value: Long): ByteArray = ByteArray(8) { (value ushr (56 - 8 * it)).toByte() }

    fun constantTimeEquals(a: ByteArray, b: ByteArray): Boolean = MessageDigest.isEqual(a, b)
}

/** AES-256-GCM in the layout the format stores everywhere: nonce (12) ‖ ciphertext ‖ tag (16). */
internal object AesGcm {
    const val NONCE_LENGTH = 12
    const val TAG_LENGTH = 16
    const val OVERHEAD = NONCE_LENGTH + TAG_LENGTH

    fun seal(key: ByteArray, nonce: ByteArray, plaintext: ByteArray, aad: ByteArray): ByteArray {
        require(key.size == 32 && nonce.size == NONCE_LENGTH)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_LENGTH * 8, nonce))
        cipher.updateAAD(aad)
        val out = ByteArray(NONCE_LENGTH + plaintext.size + TAG_LENGTH)
        System.arraycopy(nonce, 0, out, 0, NONCE_LENGTH)
        cipher.doFinal(plaintext, 0, plaintext.size, out, NONCE_LENGTH)
        return out
    }

    /** The plaintext, or null when the key, the data or the authenticated data is not what was sealed. */
    fun openOrNull(key: ByteArray, sealed: ByteArray, aad: ByteArray, offset: Int = 0, length: Int = sealed.size - offset): ByteArray? {
        if (key.size != 32 || offset < 0 || length < OVERHEAD || offset + length > sealed.size) return null
        return try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_LENGTH * 8, sealed, offset, NONCE_LENGTH))
            cipher.updateAAD(aad)
            cipher.doFinal(sealed, offset + NONCE_LENGTH, length - NONCE_LENGTH)
        } catch (_: GeneralSecurityException) {
            null
        }
    }
}

/** HKDF-SHA256 (RFC 5869). javax.crypto has no HKDF on every Android version Lelvo runs on. */
internal object Hkdf {
    private const val HASH_LENGTH = 32

    fun sha256(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int = 32): ByteArray {
        require(length in 1..255 * HASH_LENGTH)
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(if (salt.isEmpty()) ByteArray(HASH_LENGTH) else salt, "HmacSHA256"))
        val prk = mac.doFinal(ikm)
        mac.init(SecretKeySpec(prk, "HmacSHA256"))
        val out = ByteArray(length)
        var block = ByteArray(0)
        var filled = 0
        var counter = 1
        while (filled < length) {
            mac.update(block)
            mac.update(info)
            mac.update(counter.toByte())
            block = mac.doFinal()
            val n = minOf(block.size, length - filled)
            System.arraycopy(block, 0, out, filled, n)
            filled += n
            counter++
        }
        return out
    }
}
