package app.lelvo.data

import android.graphics.BitmapFactory
import android.util.Log

import app.lelvo.core.crypto.CgfeRandomReader
import app.lelvo.core.crypto.FileCrypto
import app.lelvo.core.crypto.Hashing
import app.lelvo.core.format.ByteRange
import app.lelvo.core.format.LibraryHeader
import app.lelvo.core.format.PartLayout
import app.lelvo.core.index.ItemKind
import app.lelvo.core.index.ItemStatus
import app.lelvo.core.index.LibraryItem
import app.lelvo.data.index.LibraryStore
import app.lelvo.telegram.TdFiles
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import java.io.FileInputStream
import java.io.InputStream
import java.io.OutputStream
import java.io.SequenceInputStream
import java.security.MessageDigest
import java.util.Collections
import kotlin.coroutines.cancellation.CancellationException

/**
 * Proves the base works like the iPhone on the owner's real library before any feature is built on it: header and
 * keys, a full scan, encrypted thumbnails, whole originals (SHA-256 equal to the caption), and a ranged decrypted read
 * equal to the same bytes of the whole file. Read-only: it downloads, never sends or deletes a message.
 * Results carry counts only, never names, ids or keys.
 */
class CoreCheck(
    private val files: TdFiles,
    private val library: LibraryService,
    private val scanner: LibraryScanner,
    private val store: LibraryStore,
) {
    data class Result(val name: String, val ok: Boolean?, val detail: String)

    private val _results = MutableStateFlow<List<Result>>(emptyList())
    val results: StateFlow<List<Result>> = _results
    private val _running = MutableStateFlow(false)
    val running: StateFlow<Boolean> = _running

    suspend fun run() {
        if (_running.value) return
        _running.value = true
        _results.value = emptyList()
        try {
            step("Library and keys") { checkLibrary() }
            val summary = step("Full scan") { checkScan() }
            if (summary != null) {
                val items = store.items().first().filter { it.status == ItemStatus.BackedUp }
                step("Thumbnails") { checkThumbnails(items) }
                val video = items.filter { it.kind == ItemKind.Video && it.fileSize in 1..MAX_DOWNLOAD }.minByOrNull { it.fileSize }
                val ranged = step("Ranged read") { video?.let { checkRange(it) } ?: "No video in the library to try".also { skipped = true } }
                step("Originals") { checkOriginals(items, video, ranged as? RangeProbe) }
            }
        } finally {
            _running.value = false
        }
    }

    private var skipped = false

    /** Runs one check and records it. A check returns its detail; returning a [RangeProbe] passes it on. */
    private suspend fun step(name: String, block: suspend () -> Any?): Any? {
        skipped = false
        add(Result(name, null, "Running…"))
        return try {
            val value = withContext(Dispatchers.IO) { block() }
            replace(Result(name, if (skipped) null else true, value.toString()))
            value
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "$name failed: ${e.javaClass.simpleName}")
            replace(Result(name, false, e.message ?: e.javaClass.simpleName))
            null
        }
    }

    private fun add(r: Result) { _results.value = _results.value + r }
    private fun replace(r: Result) { _results.value = _results.value.dropLast(1) + r }

    private fun checkLibrary(): String {
        val header = library.header ?: error("No library chosen")
        if (library.keys == null) error("The library is locked")
        val format = when (header) { is LibraryHeader.V2 -> "format 2"; is LibraryHeader.V1 -> "format 1"; else -> "plain" }
        if (!header.encrypted) error("Not end-to-end encrypted")
        return "Encrypted library, header $format, unlocked"
    }

    private suspend fun checkScan(): LibraryScanner.Summary {
        val s = scanner.fullScan { n -> replace(Result("Full scan", null, "$n messages read…")) }
        if (s.unreadable > 0) error("${s.unreadable} captions can't be read (of ${s.messages} messages)")
        return s
    }

    private suspend fun checkThumbnails(items: List<LibraryItem>): String {
        val sample = items.filter { it.parts["t"]?.size == 1 }.take(THUMBNAILS)
        if (sample.isEmpty()) error("No item has an encrypted thumbnail")
        val master = library.keys!!.master
        for (item in sample) {
            val part = item.parts.getValue("t").single()
            val plain = FileCrypto.decrypt(files.download(part.fileId).readBytes(), master)
            if (Hashing.sha256Hex(plain) != item.roleHashes["t"]) error("A thumbnail's hash doesn't match its caption")
            BitmapFactory.decodeByteArray(plain, 0, plain.size) ?: error("A thumbnail isn't a picture Android can show")
        }
        return "${sample.size} decrypted, hashes match, all decode"
    }

    /** Plaintext bytes read by range through TDLib, kept to compare with the whole file. */
    class RangeProbe(val item: LibraryItem, val range: ByteRange, val bytes: ByteArray) {
        override fun toString() = "${range.length} bytes from the middle of a ${item.parts.getValue("o").size}-part video, decrypted"
    }

    private suspend fun checkRange(item: LibraryItem): RangeProbe {
        val parts = item.parts.getValue("o")
        val cipherSize = parts.sumOf { it.size }
        // Every part but the last has the part size (§5).
        val layout = PartLayout(if (parts.size > 1) parts.first().size else cipherSize, cipherSize)
        suspend fun fetch(r: ByteRange): ByteArray {
            val out = java.io.ByteArrayOutputStream(r.length.toInt())
            for (seg in layout.segments(r)) out.write(files.read(parts[seg.part].fileId, seg.offset, seg.length))
            return out.toByteArray()
        }
        val reader = CgfeRandomReader(fetch(ByteRange(0, FileCrypto.HEADER_LENGTH.toLong())), cipherSize, library.keys!!.master)
        val size = reader.layout.plaintextSize
        val length = minOf(RANGE, size)
        val start = (size - length) / 2
        val range = ByteRange(start, start + length)
        val bytes = reader.read(range) { fetch(it) }
        if (bytes.size.toLong() != length) error("Read ${bytes.size} bytes, expected $length")
        return RangeProbe(item, range, bytes)
    }

    private suspend fun checkOriginals(items: List<LibraryItem>, video: LibraryItem?, probe: RangeProbe?): String {
        val photos = items.filter { it.kind != ItemKind.Video && it.fileSize in 1..MAX_DOWNLOAD }.sortedBy { it.fileSize }.take(PHOTOS)
        val sample = photos + listOfNotNull(video)
        if (sample.isEmpty()) error("Nothing small enough to download")
        val master = library.keys!!.master
        var rangeMatched = false
        for (item in sample) {
            val parts = item.parts.getValue("o")
            val local = parts.map { files.download(it.fileId) }
            try {
                if (local.zip(parts).any { (f, p) -> f.length() != p.size }) error("A downloaded part has the wrong size")
                val capture = probe?.takeIf { it.item.id == item.id }
                val sink = HashingSink(capture?.range)
                val input: InputStream = SequenceInputStream(Collections.enumeration(local.map { FileInputStream(it) }))
                input.use { FileCrypto.decrypt(it, sink, master) }
                if (sink.size != item.fileSize) error("Decrypted size differs from the caption")
                if (sink.hex() != item.sha256) error("An original's SHA-256 doesn't match its caption")
                if (capture != null) {
                    if (!sink.captured.contentEquals(capture.bytes)) error("The ranged read differs from the whole file")
                    rangeMatched = true
                }
            } finally {
                parts.forEach { files.deleteLocalCopy(it.fileId) }
            }
        }
        val kinds = "${photos.size} photo${if (photos.size == 1) "" else "s"}" + (video?.let { " and 1 video" } ?: "")
        return "$kinds: sizes and SHA-256 match" + if (rangeMatched) "; the ranged read equals the whole file" else ""
    }

    /** SHA-256 and size of everything written, keeping the bytes of one range. */
    private class HashingSink(private val keep: ByteRange?) : OutputStream() {
        private val digest = MessageDigest.getInstance("SHA-256")
        var size = 0L; private set
        val captured: ByteArray = ByteArray(keep?.length?.toInt() ?: 0)

        override fun write(b: Int) = write(byteArrayOf(b.toByte()), 0, 1)
        override fun write(b: ByteArray, off: Int, len: Int) {
            digest.update(b, off, len)
            if (keep != null) {
                val from = maxOf(size, keep.start)
                val to = minOf(size + len, keep.endExclusive)
                if (from < to) System.arraycopy(b, off + (from - size).toInt(), captured, (from - keep.start).toInt(), (to - from).toInt())
            }
            size += len
        }
        fun hex(): String = digest.digest().joinToString("") { "%02x".format(it) }
    }

    private companion object {
        const val TAG = "Lelvo.CoreCheck"
        const val THUMBNAILS = 5
        const val PHOTOS = 3
        const val RANGE = 256L * 1024
        // Keeps the check to a few minutes on mobile data.
        const val MAX_DOWNLOAD = 300L shl 20
    }
}
