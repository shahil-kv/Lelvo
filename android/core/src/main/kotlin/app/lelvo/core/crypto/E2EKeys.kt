package app.lelvo.core.crypto

import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** Key material of an end-to-end encrypted library (docs/CLOUD_FORMAT.md §6). Never log it. */
class E2EKeys(master: ByteArray) {
    val master: ByteArray = master.copyOf()

    init {
        require(master.size == 32) { "The master key is 32 bytes" }
    }

    /** §6.3. The "CloudGallery" labels are the app's first name and part of the format. */
    val captionKey: ByteArray by lazy {
        Hkdf.sha256(this.master, ByteArray(32), "CloudGallery caption v1".toByteArray(Charsets.UTF_8))
    }

    /** Header format 1: first 16 bytes of HMAC-SHA256(master, "CloudGallery key check v1"). */
    val keyCheck: ByteArray
        get() {
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(master, "HmacSHA256"))
            return mac.doFinal("CloudGallery key check v1".toByteArray(Charsets.UTF_8)).copyOf(16)
        }

    override fun toString(): String = "E2EKeys(hidden)"

    companion object {
        const val DEFAULT_ITERATIONS = 600_000L
        const val MINIMUM_ITERATIONS = 100_000L

        /**
         * Unlocking refuses more than this: the count comes from the channel header, and billions of PBKDF2 rounds
         * would keep the app busy for hours.
         */
        const val MAXIMUM_ITERATIONS = 10_000_000L

        fun random(): E2EKeys = E2EKeys(Bytes.random(32))

        /** Header format 1: the master key is the PBKDF2 output itself. */
        fun derive(passphrase: String, salt: ByteArray, iterations: Long): E2EKeys {
            if (iterations !in 1..MAXIMUM_ITERATIONS) throw CryptoException.DerivationFailed()
            return E2EKeys(KeyDerivation.pbkdf2(passphrase, salt, iterations.toInt()))
        }
    }
}

/** Captions and the captions of notes and snapshots: nonce ‖ AES-GCM(caption key, json, aad = the prefix's name) ‖ tag. */
internal object CaptionBox {
    fun seal(json: ByteArray, key: ByteArray, aad: String, nonce: ByteArray = Bytes.random(AesGcm.NONCE_LENGTH)): ByteArray =
        AesGcm.seal(key, nonce, json, aad.toByteArray(Charsets.UTF_8))

    fun openOrNull(blob: ByteArray, key: ByteArray, aad: String): ByteArray? =
        AesGcm.openOrNull(key, blob, aad.toByteArray(Charsets.UTF_8))
}

/**
 * The master key, locked with AES-256-GCM (header format 2). The purpose is authenticated, so a passphrase-locked copy
 * can't be passed off as the recovery copy or the other way round.
 */
internal object MasterKeyLock {
    enum class Purpose(val label: String) { PASSPHRASE("passphrase"), RECOVERY("recovery") }

    /** nonce (12) ‖ ciphertext (32) ‖ tag (16). */
    const val SEALED_LENGTH = 60

    // "Memvo" is the app's old name. These bytes are part of the key format: changing them locks out every
    // existing encrypted library.
    private fun aad(purpose: Purpose) = "Memvo master key v2 ${purpose.label}".toByteArray(Charsets.UTF_8)

    fun seal(master: ByteArray, key: ByteArray, purpose: Purpose, nonce: ByteArray = Bytes.random(AesGcm.NONCE_LENGTH)): ByteArray =
        AesGcm.seal(key, nonce, master, aad(purpose))

    fun open(sealed: ByteArray, key: ByteArray, purpose: Purpose): ByteArray? =
        AesGcm.openOrNull(key, sealed, aad(purpose))?.takeIf { it.size == 32 }
}

/**
 * What a passphrase becomes before it locks a library. An iPhone's Smart Punctuation turns ' into ’ and -- into — in a
 * visible text field, while a hidden field, a Mac and Android keyboards keep what was typed. Typographic quotes, dashes
 * and ellipses go back to the keys that make them. Nothing else changes, so a passphrase without them is byte for byte
 * what every version of Lelvo uses.
 */
object Passphrase {
    fun normalized(typed: String): String {
        val out = StringBuilder(typed.length)
        var i = 0
        while (i < typed.length) {
            val cp = typed.codePointAt(i)
            i += Character.charCount(cp)
            // The iPhone compares whole characters: a quote with a combining mark on it is another character there
            // and stays as typed. Doing the same keeps the two apps on the same bytes.
            val standsAlone = i >= typed.length || !extendsPrevious(typed.codePointAt(i))
            val replacement = if (standsAlone) replacement(cp) else null
            if (replacement != null) out.append(replacement) else out.appendCodePoint(cp)
        }
        return out.toString()
    }

    private fun replacement(cp: Int): String? = when (cp) {
        0x2018, 0x2019, 0x201A, 0x201B -> "'"
        0x201C, 0x201D, 0x201E, 0x201F -> "\""
        0x2014 -> "--"
        0x2026 -> "..."
        0x00A0 -> " "
        else -> null
    }

    private fun extendsPrevious(cp: Int): Boolean = cp == 0x200D || cp == 0x200C || when (Character.getType(cp).toByte()) {
        Character.NON_SPACING_MARK, Character.ENCLOSING_MARK, Character.COMBINING_SPACING_MARK -> true
        else -> false
    }

    /**
     * What to try when unlocking: as typed first (how every library was locked before November 2026), then normalized,
     * then without a stray space at either end (pasted from a note, or added by a keyboard).
     */
    fun candidates(typed: String): List<String> {
        val normalized = normalized(typed)
        val out = ArrayList<String>(3)
        for (c in listOf(typed, normalized, trimmed(normalized))) {
            if (c.isNotEmpty() && c !in out) out.add(c)
        }
        return out
    }

    // Kotlin's trim() and the iPhone's whitespacesAndNewlines disagree on a few control characters; this is the
    // iPhone's set (Unicode Z*, U+0009–U+000D, U+0085).
    private fun trimmed(text: String): String {
        fun space(cp: Int) = cp in 0x09..0x0D || cp == 0x85 || when (Character.getType(cp).toByte()) {
            Character.SPACE_SEPARATOR, Character.LINE_SEPARATOR, Character.PARAGRAPH_SEPARATOR -> true
            else -> false
        }
        var start = 0
        var end = text.length
        while (start < end && space(text.codePointAt(start))) start += Character.charCount(text.codePointAt(start))
        while (end > start && space(text.codePointBefore(end))) end -= Character.charCount(text.codePointBefore(end))
        return text.substring(start, end)
    }
}

/**
 * A recovery key: 32 random bytes the user writes down, shown as 13 groups of 4 letters and digits (RFC 4648 base32
 * without padding). It opens the library when the passphrase is forgotten. Never log it.
 */
class RecoveryKey private constructor(bytes: ByteArray) {
    val bytes: ByteArray = bytes.copyOf()

    /** The key that locks the master key's recovery copy. The "Memvo" label is the old app name and part of the format. */
    internal val lockKey: ByteArray
        get() = Hkdf.sha256(bytes, ByteArray(32), "Memvo recovery key v2".toByteArray(Charsets.UTF_8))

    /** "ABCD-EFGH-…", 13 groups. */
    val text: String
        get() {
            val out = StringBuilder(64)
            var bits = 0
            var value = 0
            var count = 0
            fun emit(index: Int) {
                if (count > 0 && count % 4 == 0) out.append('-')
                out.append(ALPHABET[index])
                count++
            }
            for (b in bytes) {
                value = ((value shl 8) or (b.toInt() and 0xFF)) and 0xFFFF
                bits += 8
                while (bits >= 5) {
                    emit((value shr (bits - 5)) and 31)
                    bits -= 5
                }
            }
            if (bits > 0) emit((value shl (5 - bits)) and 31)
            return out.toString()
        }

    override fun equals(other: Any?): Boolean = other is RecoveryKey && Bytes.constantTimeEquals(bytes, other.bytes)
    override fun hashCode(): Int = bytes.contentHashCode()
    override fun toString(): String = "RecoveryKey(hidden)"

    companion object {
        private const val ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

        fun random(): RecoveryKey = RecoveryKey(Bytes.random(32))

        fun of(bytes: ByteArray): RecoveryKey? = if (bytes.size == 32) RecoveryKey(bytes) else null

        /**
         * Reads a typed or pasted key: case, spaces, line breaks and dashes don't matter, and the digits 0, 1 and 8
         * count as the letters O, I and B they're easily mistaken for.
         */
        fun parse(text: String): RecoveryKey? {
            val cleaned = StringBuilder(52)
            for (raw in text) {
                // Dashes of any kind: a keyboard or a notes app may have turned "-" into a typographic one.
                if (raw.isWhitespace() || raw == '-' || raw in '‐'..'―' || raw == '−') continue
                // uppercaseChar() ignores the phone's language; in Turkish, "i".uppercase(locale) is not "I".
                cleaned.append(
                    when (val c = raw.uppercaseChar()) {
                        '0' -> 'O'
                        '1' -> 'I'
                        '8' -> 'B'
                        else -> c
                    },
                )
                if (cleaned.length > 52) return null
            }
            if (cleaned.length != 52) return null
            val out = ByteArray(32)
            var filled = 0
            var bits = 0
            var value = 0
            for (c in cleaned) {
                val index = ALPHABET.indexOf(c)
                if (index < 0) return null
                value = ((value shl 5) or index) and 0xFFFF
                bits += 5
                if (bits >= 8 && filled < 32) {
                    out[filled++] = ((value shr (bits - 8)) and 0xFF).toByte()
                    bits -= 8
                }
            }
            return RecoveryKey(out)
        }
    }
}
