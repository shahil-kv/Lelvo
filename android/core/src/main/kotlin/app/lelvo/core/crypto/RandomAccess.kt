package app.lelvo.core.crypto

import app.lelvo.core.format.ByteRange

/** Geometry of a CGFE ciphertext (docs/CLOUD_FORMAT.md §6.2), for random-access reads. */
data class CgfeLayout(val chunkSize: Int, val cipherSize: Long) {
    private val sealedChunk: Long get() = chunkSize.toLong() + FileCrypto.OVERHEAD_PER_CHUNK

    val chunkCount: Long
        get() = maxOf(1L, (maxOf(0L, cipherSize - FileCrypto.HEADER_LENGTH) + sealedChunk - 1) / sealedChunk)

    val plaintextSize: Long get() = cipherSize - FileCrypto.HEADER_LENGTH - chunkCount * FileCrypto.OVERHEAD_PER_CHUNK

    /** False for a size no CGFE file has: shorter than one empty chunk, or ending inside a nonce or tag. */
    val isWholeFile: Boolean
        get() = cipherSize - FileCrypto.HEADER_LENGTH - (chunkCount - 1) * sealedChunk >= FileCrypto.OVERHEAD_PER_CHUNK

    /** Byte range of sealed chunk `index` inside the ciphertext. */
    fun cipherRange(index: Long): ByteRange {
        val start = FileCrypto.HEADER_LENGTH + index * sealedChunk
        return ByteRange(start, minOf(cipherSize, start + sealedChunk))
    }

    /** First and last chunk index needed for a plaintext range. */
    fun chunksCovering(plaintext: ByteRange): LongRange {
        val first = plaintext.start / chunkSize
        val last = maxOf(first, (maxOf(plaintext.endExclusive, plaintext.start + 1) - 1) / chunkSize)
        return first..minOf(last, chunkCount - 1)
    }
}

/**
 * Decrypts arbitrary plaintext ranges of a CGFE file, fetching only the ciphertext needed: what a video player's
 * `DataSource` does on every seek. The ciphertext of a split file is one stream; map the range asked for onto parts
 * with `PartLayout.segments`.
 */
class CgfeRandomReader(header: ByteArray, cipherSize: Long, masterKey: ByteArray) {
    val layout: CgfeLayout
    private val header: ByteArray
    private val key: ByteArray

    init {
        val parsed = FileCrypto.parseHeader(header)
        this.header = parsed.bytes
        layout = CgfeLayout(parsed.chunkSize, cipherSize)
        if (!layout.isWholeFile) throw CryptoException.Truncated()
        key = FileCrypto.fileKey(masterKey, parsed.salt)
    }

    fun decryptChunk(index: Long, sealed: ByteArray, offset: Int = 0, length: Int = sealed.size - offset): ByteArray {
        if (index !in 0 until layout.chunkCount) throw CryptoException.BadFormat()
        // A short answer from the network is not a damaged file; say which it is.
        if (length.toLong() != layout.cipherRange(index).length || offset < 0 || offset + length > sealed.size) throw CryptoException.Truncated()
        val isFinal = index == layout.chunkCount - 1
        return AesGcm.openOrNull(key, sealed, FileCrypto.aad(header, index, isFinal), offset, length)
            ?: throw CryptoException.WrongKeyOrCorrupt()
    }

    /** What one read needs: `cipherRange` is the ciphertext to fetch, null when the cache already has every chunk. */
    class Plan internal constructor(
        internal val plaintext: ByteRange,
        internal val chunks: LongRange,
        internal val have: MutableMap<Long, ByteArray>,
        internal val missing: LongRange?,
        val cipherRange: ByteRange?,
    )

    /** Null when `plaintext` is empty or past the end. */
    fun plan(plaintext: ByteRange, cache: DecryptedChunkCache? = null, file: String = ""): Plan? {
        val clamped = ByteRange(maxOf(0, plaintext.start), minOf(layout.plaintextSize, plaintext.endExclusive))
        if (clamped.isEmpty) return null
        require(clamped.length <= Int.MAX_VALUE - 2L * (layout.chunkSize + FileCrypto.OVERHEAD_PER_CHUNK)) { "Read in smaller pieces" }
        val chunks = layout.chunksCovering(clamped)
        val have = HashMap<Long, ByteArray>()
        if (cache != null) for (i in chunks) cache.chunk(file, i)?.let { have[i] = it }
        val firstMissing = chunks.firstOrNull { it !in have }
        val lastMissing = chunks.lastOrNull { it !in have }
        if (firstMissing == null || lastMissing == null) return Plan(clamped, chunks, have, null, null)
        // The player asks for small pieces of big chunks; the chunks not in the cache are fetched as one range.
        val cipher = ByteRange(layout.cipherRange(firstMissing).start, layout.cipherRange(lastMissing).endExclusive)
        return Plan(clamped, chunks, have, firstMissing..lastMissing, cipher)
    }

    /** The plaintext of `plan`, given the bytes of its `cipherRange`. */
    fun finish(plan: Plan, cipher: ByteArray?, cache: DecryptedChunkCache? = null, file: String = ""): ByteArray {
        val missing = plan.missing
        val cipherRange = plan.cipherRange
        if (missing != null && cipherRange != null) {
            if (cipher == null || cipher.size < cipherRange.length) throw CryptoException.Truncated()
            for (i in missing) {
                if (i in plan.have) continue
                val r = layout.cipherRange(i)
                val chunk = decryptChunk(i, cipher, (r.start - cipherRange.start).toInt(), r.length.toInt())
                cache?.store(file, i, chunk)
                plan.have[i] = chunk
            }
        }
        val out = ByteArray(plan.plaintext.length.toInt())
        var filled = 0
        for (i in plan.chunks) {
            val chunk = plan.have[i] ?: continue
            val chunkStart = i * layout.chunkSize
            val from = maxOf(plan.plaintext.start, chunkStart) - chunkStart
            val to = minOf(plan.plaintext.endExclusive, chunkStart + chunk.size) - chunkStart
            if (to > from) {
                System.arraycopy(chunk, from.toInt(), out, filled, (to - from).toInt())
                filled += (to - from).toInt()
            }
        }
        return if (filled == out.size) out else out.copyOf(filled)
    }

    /**
     * Reads plaintext `range`, calling `fetch` at most once for the ciphertext it needs. Inline so that `fetch` may
     * suspend when the caller does.
     */
    inline fun read(range: ByteRange, cache: DecryptedChunkCache? = null, file: String = "", fetch: (ByteRange) -> ByteArray): ByteArray {
        val plan = plan(range, cache, file) ?: return ByteArray(0)
        val cipher = plan.cipherRange?.let { fetch(it) }
        return finish(plan, cipher, cache, file)
    }
}

/**
 * The last few decrypted CGFE chunks, least recently used dropped first. Small on purpose (a few MiB): it only has to
 * cover the pieces a player asks for around its playhead.
 */
class DecryptedChunkCache(private val limit: Int = 4 shl 20) {
    private data class Key(val file: String, val index: Long)

    // Access order: iteration starts at the least recently used.
    private val chunks = LinkedHashMap<Key, ByteArray>(16, 0.75f, true)
    private var bytes = 0

    val totalBytes: Int get() = synchronized(this) { bytes }

    fun chunk(file: String, index: Long): ByteArray? = synchronized(this) { chunks[Key(file, index)] }

    fun store(file: String, index: Long, data: ByteArray) {
        if (data.size > limit) return
        synchronized(this) {
            chunks.put(Key(file, index), data)?.let { bytes -= it.size }
            bytes += data.size
            val oldest = chunks.entries.iterator()
            while (bytes > limit && oldest.hasNext()) {
                bytes -= oldest.next().value.size
                oldest.remove()
            }
        }
    }

    /** Drops every chunk of one file (its player closed). */
    fun remove(file: String) = synchronized(this) {
        val all = chunks.entries.iterator()
        while (all.hasNext()) {
            val entry = all.next()
            if (entry.key.file == file) {
                bytes -= entry.value.size
                all.remove()
            }
        }
    }

    fun removeAll() = synchronized(this) {
        chunks.clear()
        bytes = 0
    }
}
