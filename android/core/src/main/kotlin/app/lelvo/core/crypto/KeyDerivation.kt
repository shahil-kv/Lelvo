package app.lelvo.core.crypto

import javax.crypto.SecretKeyFactory
import javax.crypto.spec.PBEKeySpec

object KeyDerivation {
    const val SALT_LENGTH = 16

    fun randomSalt(count: Int = SALT_LENGTH): ByteArray = Bytes.random(count)

    /** PBKDF2-HMAC-SHA256 over the NFC UTF-8 passphrase (header format 1, docs/CLOUD_FORMAT.md §6.1). */
    fun pbkdf2(passphrase: String, salt: ByteArray, iterations: Int, keyLength: Int = 32): ByteArray {
        val password = passphrase.nfc().toCharArray()
        if (password.isEmpty() || salt.isEmpty() || iterations < 1) throw CryptoException.DerivationFailed()
        // PBEKeySpec takes characters and the provider turns them into UTF-8 itself.
        val spec = PBEKeySpec(password, salt, iterations, keyLength * 8)
        try {
            return SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded
        } catch (_: java.security.GeneralSecurityException) {
            throw CryptoException.DerivationFailed()
        } finally {
            spec.clearPassword()
            password.fill('\u0000')
        }
    }
}

/**
 * Argon2id (RFC 9106, version 0x13), the passphrase derivation of header format 2. The module stays pure Kotlin, so the
 * app supplies the implementation (argon2kt on Android; Bouncy Castle in the JVM tests).
 */
fun interface Argon2id {
    fun hash(password: ByteArray, salt: ByteArray, iterations: Int, memoryKiB: Int, parallelism: Int, length: Int): ByteArray
}

/** Argon2id cost as the header stores it (`a2:<t>,<m>,<p>`). The header's numbers are 32-bit unsigned, hence Long. */
data class Argon2Parameters(val iterations: Long, val memoryKiB: Long, val parallelism: Int = 1) {
    /** True when this cost is one Lelvo agrees to compute. */
    val isWithinLimits: Boolean
        get() = iterations in 1..MAXIMUM_ITERATIONS && memoryKiB in MINIMUM_MEMORY_KIB..MAXIMUM_MEMORY_KIB

    companion object {
        /** New libraries: 256 MiB, 3 passes. */
        val STANDARD = Argon2Parameters(iterations = 3, memoryKiB = 256 * 1024)

        /** Readers refuse less than this. */
        const val MINIMUM_MEMORY_KIB = 19L * 1024

        /**
         * Unlocking refuses more than this. The cost comes from the channel header, so without a ceiling an edited
         * header could ask for gigabytes (Android ends the app) or billions of passes (it never finishes).
         */
        const val MAXIMUM_MEMORY_KIB = 1024L * 1024
        const val MAXIMUM_ITERATIONS = 10L
    }
}

/** The passphrase key for these parameters. Throws [CryptoException.DerivationFailed] for input Argon2 can't take. */
internal fun Argon2id.derive(passphrase: String, salt: ByteArray, parameters: Argon2Parameters, length: Int = 32): ByteArray {
    val password = passphrase.nfc().toByteArray(Charsets.UTF_8)
    if (password.isEmpty() || salt.size < 8 || !parameters.isWithinLimits || parameters.parallelism !in 1..16 ||
        parameters.memoryKiB < 8L * parameters.parallelism
    ) {
        throw CryptoException.DerivationFailed()
    }
    val out = try {
        hash(password, salt, parameters.iterations.toInt(), parameters.memoryKiB.toInt(), parameters.parallelism, length)
    } catch (_: Exception) {
        throw CryptoException.DerivationFailed()
    } finally {
        password.fill(0)
    }
    if (out.size != length) throw CryptoException.DerivationFailed()
    return out
}
