package app.lelvo.core.format

import app.lelvo.core.LelvoFormat
import app.lelvo.core.crypto.Argon2Parameters
import app.lelvo.core.crypto.Argon2id
import app.lelvo.core.crypto.Bytes
import app.lelvo.core.crypto.CryptoException
import app.lelvo.core.crypto.E2EKeys
import app.lelvo.core.crypto.KeyDerivation
import app.lelvo.core.crypto.MasterKeyLock
import app.lelvo.core.crypto.Passphrase
import app.lelvo.core.crypto.RecoveryKey
import app.lelvo.core.crypto.derive

/** What reading a pinned message or a channel description found. */
sealed class HeaderResult {
    /** No header line at all: not a Lelvo library (yet). */
    object Missing : HeaderResult()

    data class Found(val header: LibraryHeader) : HeaderResult()

    /** Set up by a newer Lelvo: don't read, write or "repair" the channel; ask the user to update. */
    data class Newer(val version: Int) : HeaderResult()

    /**
     * A header line is there but can't be read (cut short, a cost below the minimum, an unknown flag). It is a Lelvo
     * library all the same: never treat it as a channel without a header and write a new one over it.
     */
    object Damaged : HeaderResult()
}

/**
 * The library header (docs/CLOUD_FORMAT.md §1, §6.1).
 *
 * Format 1 derives the master key straight from the passphrase (PBKDF2). Format 2 keeps a master key that is only
 * stored locked: once with a key from the passphrase (Argon2id) and once with a recovery key. Android reads both and
 * writes format 2 only.
 */
sealed class LibraryHeader {
    abstract val version: Int
    abstract val encrypted: Boolean

    /** The header as one line, without the pinned message's tag. */
    abstract val line: String

    /** A library without encryption. Android can tell it apart, and asks the user to open it on iPhone or Mac. */
    object Plain : LibraryHeader() {
        override val version = 1
        override val encrypted = false
        override val line = "cg:1"
    }

    class V1(val iterations: Long, salt: ByteArray, keyCheck: ByteArray) : LibraryHeader() {
        val salt: ByteArray = salt.copyOf()
        val keyCheck: ByteArray = keyCheck.copyOf()
        override val version = 1
        override val encrypted = true
        override val line: String get() = "cg:1;e2e:1;it:$iterations;s:${Bytes.base64(salt)};kc:${Bytes.base64(keyCheck)}"

        /**
         * The keys for this passphrase, or null when it's wrong. Throws [CryptoException.DerivationFailed] when the
         * header asks for more rounds than Lelvo computes; the library still counts as encrypted.
         */
        fun unlock(passphrase: String): E2EKeys? {
            for (candidate in Passphrase.candidates(passphrase)) {
                val keys = E2EKeys.derive(candidate, salt, iterations)
                if (Bytes.constantTimeEquals(keys.keyCheck, keyCheck)) return keys
            }
            return null
        }

        override fun equals(other: Any?): Boolean =
            other is V1 && iterations == other.iterations && salt.contentEquals(other.salt) && keyCheck.contentEquals(other.keyCheck)
        override fun hashCode(): Int = salt.contentHashCode()
    }

    class V2(val argon: Argon2Parameters, salt: ByteArray, lockedByPassphrase: ByteArray, lockedByRecoveryKey: ByteArray) : LibraryHeader() {
        val salt: ByteArray = salt.copyOf()

        /** The master key locked with the passphrase key, and with the recovery key (nonce ‖ ciphertext ‖ tag). */
        val lockedByPassphrase: ByteArray = lockedByPassphrase.copyOf()
        val lockedByRecoveryKey: ByteArray = lockedByRecoveryKey.copyOf()
        override val version = 2
        override val encrypted = true
        override val line: String
            get() = "cg:2;e2e:1;a2:${argon.iterations},${argon.memoryKiB},${argon.parallelism};s:${Bytes.base64(salt)}" +
                ";wk:${Bytes.base64(lockedByPassphrase)};rk:${Bytes.base64(lockedByRecoveryKey)}"

        /**
         * The pinned header message. It also carries a format 1 line with random values: versions from before format 2
         * read that one, ask for the passphrase and always find it wrong, instead of taking the channel for one without
         * a header. The channel description holds `line` alone.
         */
        val messageText: String
            get() {
                val decoy = V1(E2EKeys.DEFAULT_ITERATIONS, KeyDerivation.randomSalt(), KeyDerivation.randomSalt())
                return MESSAGE_PREFIX + line + "\n" + MESSAGE_PREFIX + decoy.line
            }

        /**
         * The keys for this passphrase, or null when it's wrong. Tries it exactly as typed, then in its normalized
         * forms (§6.1). Throws [CryptoException.DerivationFailed] when the header asks for a cost beyond the limits.
         */
        fun unlock(passphrase: String, argon2: Argon2id): E2EKeys? {
            if (!argon.isWithinLimits) throw CryptoException.DerivationFailed()
            for (candidate in Passphrase.candidates(passphrase)) {
                val key = argon2.derive(candidate, salt, argon)
                MasterKeyLock.open(lockedByPassphrase, key, MasterKeyLock.Purpose.PASSPHRASE)?.let { return E2EKeys(it) }
            }
            return null
        }

        /** The keys for this recovery key, or null when it doesn't belong to this library. */
        fun unlock(recoveryKey: RecoveryKey): E2EKeys? =
            MasterKeyLock.open(lockedByRecoveryKey, recoveryKey.lockKey, MasterKeyLock.Purpose.RECOVERY)?.let { E2EKeys(it) }

        /** The same library with a new passphrase; the recovery key keeps working. */
        fun changingPassphrase(keys: E2EKeys, passphrase: String, argon2: Argon2id): V2 {
            val salt = KeyDerivation.randomSalt()
            val key = argon2.derive(Passphrase.normalized(passphrase), salt, argon)
            return V2(argon, salt, MasterKeyLock.seal(keys.master, key, MasterKeyLock.Purpose.PASSPHRASE), lockedByRecoveryKey)
        }

        /** The same library with a new recovery key (the old one stops working); the passphrase keeps working. */
        fun replacingRecoveryKey(keys: E2EKeys): Pair<V2, RecoveryKey> {
            val recovery = RecoveryKey.random()
            return V2(argon, salt, lockedByPassphrase, MasterKeyLock.seal(keys.master, recovery.lockKey, MasterKeyLock.Purpose.RECOVERY)) to recovery
        }

        override fun equals(other: Any?): Boolean = other is V2 && argon == other.argon && salt.contentEquals(other.salt) &&
            lockedByPassphrase.contentEquals(other.lockedByPassphrase) && lockedByRecoveryKey.contentEquals(other.lockedByRecoveryKey)
        override fun hashCode(): Int = salt.contentHashCode()
    }

    class NewLibrary(val header: V2, val keys: E2EKeys, val recoveryKey: RecoveryKey)

    companion object {
        const val MESSAGE_PREFIX = "#cloudgallery-library "
        private const val TAG = "#cloudgallery-library"
        private const val UINT32_MAX = 4_294_967_295L
        private val LINE_BREAKS = Regex("[\\n\\r\\u000B\\u000C\\u0085\\u2028\\u2029]")

        /** A new encrypted library: a random master key, locked with the passphrase and a new recovery key. */
        fun newLibrary(passphrase: String, argon2: Argon2id, argon: Argon2Parameters = Argon2Parameters.STANDARD): NewLibrary {
            val keys = E2EKeys.random()
            val recovery = RecoveryKey.random()
            return NewLibrary(locking(keys, passphrase, argon2, recovery, argon), keys, recovery)
        }

        /** Format 2 for a master key, which stays as it is. */
        internal fun locking(
            keys: E2EKeys, passphrase: String, argon2: Argon2id, recoveryKey: RecoveryKey, argon: Argon2Parameters,
            salt: ByteArray = KeyDerivation.randomSalt(), passphraseNonce: ByteArray = Bytes.random(12), recoveryNonce: ByteArray = Bytes.random(12),
        ): V2 {
            val key = argon2.derive(Passphrase.normalized(passphrase), salt, argon)
            return V2(
                argon, salt,
                MasterKeyLock.seal(keys.master, key, MasterKeyLock.Purpose.PASSPHRASE, passphraseNonce),
                MasterKeyLock.seal(keys.master, recoveryKey.lockKey, MasterKeyLock.Purpose.RECOVERY, recoveryNonce),
            )
        }

        /**
         * Reads the header from a pinned message text or a channel description. Of several header lines the newest
         * readable one wins; any line from a newer format makes the whole header `Newer`.
         */
        fun parse(text: String): HeaderResult {
            var best: LibraryHeader? = null
            // The highest format among header lines that couldn't be read; 0 when there is none.
            var damaged = 0
            for (raw in text.split(LINE_BREAKS)) {
                var line = raw.trim()
                val tagged = line.startsWith(TAG)
                if (tagged) line = line.substring(TAG.length).trim()
                if (!line.startsWith("cg:")) continue
                val fields = HashMap<String, String>()
                for (pair in line.split(';')) {
                    val kv = pair.split(':', limit = 2)
                    if (kv.size == 2 && kv[0].isNotEmpty() && kv[1].isNotEmpty()) fields[kv[0]] = kv[1]
                }
                val number = fields["cg"]?.takeIf { it.length <= 18 }?.let(::unsigned)
                    ?: fields["cg"]?.takeIf { it.all { c -> c in '0'..'9' } }?.let { Long.MAX_VALUE }
                if (number == null) {
                    // "cg:" starting a line of an ordinary channel's description is just text. Under the tag it was
                    // meant as a header.
                    if (tagged) damaged = maxOf(damaged, 1)
                    continue
                }
                if (number > LelvoFormat.readableHeaderFormats.max()) return HeaderResult.Newer(minOf(number, Int.MAX_VALUE.toLong()).toInt())
                val header = when (number) {
                    1L -> parseVersion1(fields)
                    2L -> parseVersion2(fields)
                    else -> null
                }
                if (header == null) {
                    damaged = maxOf(damaged, number.toInt().coerceAtLeast(1))
                } else if ((best?.version ?: 0) < header.version) {
                    best = header
                }
            }
            if (best == null) return if (damaged > 0) HeaderResult.Damaged else HeaderResult.Missing
            // A damaged format 2 line next to its format 1 decoy must not turn into "wrong passphrase" for ever, and a
            // damaged encrypted line next to a plain one must not turn into a plain library.
            if (damaged > best.version || (damaged == best.version && !best.encrypted)) return HeaderResult.Damaged
            return HeaderResult.Found(best)
        }

        private fun unsigned(text: String): Long? = if (text.isNotEmpty() && text.all { it in '0'..'9' }) text.toLongOrNull() else null

        private fun parseVersion1(fields: Map<String, String>): LibraryHeader? {
            val e2e = fields["e2e"] ?: return Plain
            if (e2e != "1") return null
            val iterations = fields["it"]?.let(::unsigned)?.takeIf { it in E2EKeys.MINIMUM_ITERATIONS..UINT32_MAX } ?: return null
            val salt = fields["s"]?.let(Bytes::base64OrNull)?.takeIf { it.size == 16 } ?: return null
            val keyCheck = fields["kc"]?.let(Bytes::base64OrNull)?.takeIf { it.size == 16 } ?: return null
            return V1(iterations, salt, keyCheck)
        }

        private fun parseVersion2(fields: Map<String, String>): LibraryHeader? {
            if (fields["e2e"] != "1") return null
            val cost = (fields["a2"] ?: return null).split(',').map { unsigned(it)?.takeIf { n -> n <= UINT32_MAX } ?: return null }
            if (cost.size != 3 || cost[0] < 1 || cost[1] < Argon2Parameters.MINIMUM_MEMORY_KIB || cost[2] !in 1..16) return null
            val salt = fields["s"]?.let(Bytes::base64OrNull)?.takeIf { it.size == 16 } ?: return null
            val wk = fields["wk"]?.let(Bytes::base64OrNull)?.takeIf { it.size == MasterKeyLock.SEALED_LENGTH } ?: return null
            val rk = fields["rk"]?.let(Bytes::base64OrNull)?.takeIf { it.size == MasterKeyLock.SEALED_LENGTH } ?: return null
            return V2(Argon2Parameters(cost[0], cost[1], cost[2].toInt()), salt, wk, rk)
        }
    }
}
