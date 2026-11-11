package app.lelvo.core.crypto

import app.lelvo.core.format.PartLayout
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream

/**
 * CGFE: chunked AES-256-GCM for every file of an encrypted library (docs/CLOUD_FORMAT.md §6.2).
 *
 * Layout: `"CGFE" | version (1) | chunk size (UInt32 BE) | file salt (16)` followed by chunks of
 * `nonce (12) | ciphertext (≤ chunk size) | tag (16)`. Each chunk authenticates the header, its index and a final-chunk
 * flag, so reordering, truncation or appending is detected. The per-file key is HKDF-SHA256(master key, file salt), so
 * the master key never encrypts data directly.
 */
object FileCrypto {
    const val VERSION = 1
    const val DEFAULT_CHUNK_SIZE = 1 shl 20

    /** Fast versions (role `sp`) are streamed: a player shows nothing until the first whole chunk arrived. */
    const val FAST_VERSION_CHUNK_SIZE = 256 shl 10
    const val HEADER_LENGTH = 4 + 1 + 4 + 16
    const val OVERHEAD_PER_CHUNK = AesGcm.OVERHEAD

    /** Readers accept 4 KiB to 64 MiB; nothing is written outside it, so every reader can open it. */
    const val MINIMUM_CHUNK_SIZE = 4096
    const val MAXIMUM_CHUNK_SIZE = 64 shl 20

    private val MAGIC = byteArrayOf('C'.code.toByte(), 'G'.code.toByte(), 'F'.code.toByte(), 'E'.code.toByte())

    fun isEncrypted(prefix: ByteArray): Boolean = prefix.size >= 4 && (0 until 4).all { prefix[it] == MAGIC[it] }

    /** Size of the ciphertext produced for a plaintext of `plaintextSize` bytes. An empty file is one empty chunk. */
    fun encryptedSize(plaintextSize: Long, chunkSize: Int = DEFAULT_CHUNK_SIZE): Long {
        val chunks = maxOf(1L, (plaintextSize + chunkSize - 1) / chunkSize)
        return HEADER_LENGTH + plaintextSize + chunks * OVERHEAD_PER_CHUNK
    }

    class Header internal constructor(val chunkSize: Int, internal val salt: ByteArray, internal val bytes: ByteArray)

    /** Reads the 25-byte header at the start of `prefix`. */
    fun parseHeader(prefix: ByteArray): Header {
        if (prefix.size < HEADER_LENGTH) throw CryptoException.Truncated()
        if (!isEncrypted(prefix)) throw CryptoException.BadFormat()
        val version = prefix[4].toInt() and 0xFF
        if (version != VERSION) throw CryptoException.UnsupportedVersion(version)
        var chunk = 0L
        for (i in 5 until 9) chunk = (chunk shl 8) or (prefix[i].toLong() and 0xFF)
        if (chunk !in MINIMUM_CHUNK_SIZE..MAXIMUM_CHUNK_SIZE) throw CryptoException.BadFormat()
        return Header(chunk.toInt(), prefix.copyOfRange(9, HEADER_LENGTH), prefix.copyOf(HEADER_LENGTH))
    }

    internal fun header(chunkSize: Int, fileSalt: ByteArray): ByteArray {
        require(chunkSize in MINIMUM_CHUNK_SIZE..MAXIMUM_CHUNK_SIZE) { "Chunk size outside what readers accept" }
        require(fileSalt.size == 16)
        return MAGIC + byteArrayOf(VERSION.toByte()) + Bytes.u32be(chunkSize) + fileSalt
    }

    internal fun fileKey(master: ByteArray, salt: ByteArray): ByteArray =
        Hkdf.sha256(master, salt, "CloudGallery file v1".toByteArray(Charsets.UTF_8))

    internal fun aad(header: ByteArray, index: Long, final: Boolean): ByteArray =
        header + Bytes.u64be(index) + byteArrayOf(if (final) 1 else 0)

    /** Encrypts `plaintextSize` bytes of `input` to `output`. Neither stream is closed. */
    fun encrypt(input: InputStream, plaintextSize: Long, output: OutputStream, masterKey: ByteArray, chunkSize: Int = DEFAULT_CHUNK_SIZE) {
        val encryptor = Encryptor(input, plaintextSize, masterKey, chunkSize)
        while (true) {
            val bytes = encryptor.read(1 shl 20)
            if (bytes.isEmpty()) break
            output.write(bytes)
        }
    }

    /**
     * Decrypts a whole CGFE stream. Plaintext is written chunk by chunk as each one checks out, so when this throws,
     * what was written so far is the start of the file only: the caller deletes it.
     */
    fun decrypt(input: InputStream, output: OutputStream, masterKey: ByteArray) {
        val head = readUpTo(input, HEADER_LENGTH)
        val header = parseHeader(head)
        val key = fileKey(masterKey, header.salt)
        val sealedChunk = header.chunkSize + OVERHEAD_PER_CHUNK
        var index = 0L
        var current = readUpTo(input, sealedChunk)
        while (true) {
            if (current.size < OVERHEAD_PER_CHUNK) throw CryptoException.Truncated()
            // A chunk is final when nothing follows it. A file cut at a chunk boundary then fails its tag, because
            // the chunk now last was sealed as "not final".
            val next = if (current.size == sealedChunk) readUpTo(input, sealedChunk) else ByteArray(0)
            val isFinal = next.isEmpty()
            val plain = AesGcm.openOrNull(key, current, aad(header.bytes, index, isFinal)) ?: throw CryptoException.WrongKeyOrCorrupt()
            output.write(plain)
            if (isFinal) break
            current = next
            index++
        }
    }

    fun encrypt(data: ByteArray, masterKey: ByteArray, chunkSize: Int = DEFAULT_CHUNK_SIZE): ByteArray =
        readAll(Encryptor(ByteArrayInputStream(data), data.size.toLong(), masterKey, chunkSize))

    fun decrypt(data: ByteArray, masterKey: ByteArray): ByteArray {
        val out = ByteArrayOutputStream(maxOf(0, data.size - HEADER_LENGTH))
        decrypt(ByteArrayInputStream(data), out, masterKey)
        return out.toByteArray()
    }

    /** Fixed salt and nonces, for the cross-platform test vectors only. */
    internal fun encryptForTesting(data: ByteArray, masterKey: ByteArray, chunkSize: Int, fileSalt: ByteArray, nonces: List<ByteArray>): ByteArray =
        readAll(Encryptor(ByteArrayInputStream(data), data.size.toLong(), masterKey, chunkSize, fileSalt, nonces))

    private fun readAll(encryptor: Encryptor): ByteArray {
        val out = ByteArrayOutputStream(encryptor.cipherSize.toInt())
        while (true) {
            val bytes = encryptor.read(1 shl 20)
            if (bytes.isEmpty()) break
            out.write(bytes)
        }
        return out.toByteArray()
    }

    /** Up to `count` bytes; fewer only at the end of the stream. */
    internal fun readUpTo(input: InputStream, count: Int): ByteArray {
        val buffer = ByteArray(count)
        var filled = 0
        while (filled < count) {
            val n = input.read(buffer, filled, count - filled)
            if (n < 0) break
            filled += n
        }
        return if (filled == count) buffer else buffer.copyOf(filled)
    }

    /**
     * Where an interrupted encrypted upload stopped: enough to make the rest of the same ciphertext. Chunk boundaries
     * don't line up with part boundaries (the header shifts them by 25 bytes), so the chunk crossing the cut is sealed
     * again with its old nonce, which gives the very same bytes. That is only safe for the very same plaintext: reusing
     * a GCM nonce for other bytes gives the key away, hence `plaintextHash`. Nothing here is secret: the salt and
     * nonces are stored in the clear in the uploaded parts.
     */
    class ResumePoint(
        /** Ciphertext bytes already uploaded. */
        val cipherOffset: Long,
        val chunkSize: Int,
        fileSalt: ByteArray,
        /** Nonce of the chunk crossing `cipherOffset`; null when a chunk starts exactly there. */
        nonce: ByteArray?,
        /** SHA-256 (hex) of the plaintext, set by the caller and checked before resuming. */
        val plaintextHash: String,
    ) {
        val fileSalt: ByteArray = fileSalt.copyOf()
        val nonce: ByteArray? = nonce?.copyOf()

        /**
         * True when the parts confirmed so far (their sizes, in order) end exactly here and the file and its
         * encryption are the same as before. Anything else starts over.
         */
        fun continues(partSizes: List<Long>, layout: PartLayout, chunkSize: Int, plaintextHash: String): Boolean =
            partSizes.isNotEmpty() && partSizes.size < layout.partCount &&
                chunkSize == this.chunkSize && plaintextHash == this.plaintextHash && fileSalt.size == 16 &&
                partSizes.withIndex().all { (i, size) -> size == layout.sizeOfPart(i) } &&
                cipherOffset == partSizes.sum()

        override fun equals(other: Any?): Boolean = other is ResumePoint && cipherOffset == other.cipherOffset &&
            chunkSize == other.chunkSize && fileSalt.contentEquals(other.fileSalt) &&
            (nonce?.contentEquals(other.nonce) ?: (other.nonce == null)) && plaintextHash == other.plaintextHash

        override fun hashCode(): Int = cipherOffset.hashCode() * 31 + fileSalt.contentHashCode()
    }

    /**
     * The CGFE ciphertext of a file, produced in order as it's read, so a caller can write it straight into split
     * parts (one part on disk at a time) instead of encrypting a whole copy first.
     *
     * `plaintextSize` is the size the caller measured (and hashed). A source that turns out shorter or longer was
     * changed meanwhile: reading throws, and nothing counts as backed up.
     */
    class Encryptor internal constructor(
        private val input: InputStream,
        private val plaintextSize: Long,
        masterKey: ByteArray,
        private val chunkSize: Int,
        fileSalt: ByteArray,
        private val nonces: List<ByteArray>?,
    ) : Closeable {
        private val header = header(chunkSize, fileSalt)
        private val fileSalt = fileSalt.copyOf()
        private val key = fileKey(masterKey, fileSalt)
        private val chunkCount = maxOf(1L, (plaintextSize + chunkSize - 1) / chunkSize)
        private var index = 0L

        /** Ciphertext bytes handed out so far, counted from the start of the file. */
        private var offset = 0L

        /** When resuming: the nonce for the first chunk sealed, and how many of its bytes were uploaded already. */
        private var resumeNonce: ByteArray? = null
        private var resumeSkip = 0

        /** Sealed bytes not handed out yet, from `pendingStart`. */
        private var pending = header
        private var pendingStart = 0
        private var finished = false

        /** Size of the whole ciphertext. */
        val cipherSize: Long = encryptedSize(plaintextSize, chunkSize)

        constructor(input: InputStream, plaintextSize: Long, masterKey: ByteArray, chunkSize: Int = DEFAULT_CHUNK_SIZE) :
            this(input, plaintextSize, masterKey, chunkSize, Bytes.random(16), null)

        init {
            require(plaintextSize >= 0)
        }

        /** Where the bytes read so far end, to resume from there later. */
        fun resumePoint(plaintextHash: String): ResumePoint {
            // Inside a sealed chunk, `pending` holds it and starts with its nonce. Resumed with nothing read yet, the
            // cut is still the earlier point's.
            val insideChunk = offset > HEADER_LENGTH && pendingStart < pending.size
            val nonce = resumeNonce ?: if (insideChunk) pending.copyOf(AesGcm.NONCE_LENGTH) else null
            return ResumePoint(offset, chunkSize, fileSalt, nonce, plaintextHash)
        }

        internal fun resume(point: ResumePoint) {
            if (point.cipherOffset < 0 || point.cipherOffset > cipherSize) throw CryptoException.BadFormat()
            offset = point.cipherOffset
            if (point.cipherOffset == cipherSize) {
                pending = ByteArray(0)
                pendingStart = 0
                finished = true
                return
            }
            if (point.cipherOffset < HEADER_LENGTH) {
                pendingStart = point.cipherOffset.toInt()
                return
            }
            val sealed = (chunkSize + OVERHEAD_PER_CHUNK).toLong()
            val into = point.cipherOffset - HEADER_LENGTH
            index = into / sealed
            resumeSkip = (into % sealed).toInt()
            if (resumeSkip > 0) {
                // Without the old nonce the rest of this chunk wouldn't join the bytes already uploaded.
                val nonce = point.nonce
                if (nonce == null || nonce.size != AesGcm.NONCE_LENGTH) throw CryptoException.BadFormat()
                resumeNonce = nonce
            }
            skipFully(index * chunkSize)
            pending = ByteArray(0)
            pendingStart = 0
        }

        /** Up to `count` more ciphertext bytes; empty once everything was read. */
        fun read(count: Int): ByteArray {
            val out = ByteArrayOutputStream(minOf(count, 1 shl 20))
            while (out.size() < count) {
                if (pendingStart == pending.size && !sealNext()) break
                val n = minOf(count - out.size(), pending.size - pendingStart)
                out.write(pending, pendingStart, n)
                pendingStart += n
            }
            offset += out.size()
            return out.toByteArray()
        }

        /** Seals the next chunk into `pending`; false at the end. */
        private fun sealNext(): Boolean {
            if (finished) return false
            val length = minOf(chunkSize.toLong(), plaintextSize - index * chunkSize).toInt()
            val chunk = readUpTo(input, length)
            if (chunk.size != length) throw IOException("The file is shorter than when its backup started")
            val isFinal = index == chunkCount - 1
            if (isFinal && input.read() >= 0) throw IOException("The file is longer than when its backup started")
            val nonce = resumeNonce ?: nonces?.get(index.toInt()) ?: Bytes.random(AesGcm.NONCE_LENGTH)
            pending = AesGcm.seal(key, nonce, chunk, aad(header, index, isFinal))
            pendingStart = resumeSkip
            resumeNonce = null
            resumeSkip = 0
            index++
            finished = isFinal
            return true
        }

        private fun skipFully(count: Long) {
            var left = count
            while (left > 0) {
                val skipped = input.skip(left)
                if (skipped > 0) {
                    left -= skipped
                } else {
                    // skip() may return 0 without being at the end; one read tells which.
                    if (input.read() < 0) throw IOException("The file is shorter than when its backup started")
                    left--
                }
            }
        }

        override fun close() = input.close()

        companion object {
            /**
             * Continues the ciphertext of an earlier `Encryptor` from `point`: the bytes read are exactly those that
             * encryptor would have produced after `point.cipherOffset`, apart from the nonces of whole chunks, which
             * are new. `input` starts at the beginning of the file. The caller checks first that it is the same
             * plaintext (`ResumePoint.continues`).
             */
            fun resuming(input: InputStream, plaintextSize: Long, masterKey: ByteArray, point: ResumePoint): Encryptor =
                resuming(input, plaintextSize, masterKey, point, null)

            internal fun resuming(input: InputStream, plaintextSize: Long, masterKey: ByteArray, point: ResumePoint, nonces: List<ByteArray>?): Encryptor {
                if (point.fileSalt.size != 16 || point.chunkSize !in MINIMUM_CHUNK_SIZE..MAXIMUM_CHUNK_SIZE) throw CryptoException.BadFormat()
                return Encryptor(input, plaintextSize, masterKey, point.chunkSize, point.fileSalt, nonces).also { it.resume(point) }
            }
        }
    }
}
