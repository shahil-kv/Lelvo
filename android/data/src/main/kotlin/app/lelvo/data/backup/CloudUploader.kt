package app.lelvo.data.backup

import android.os.StatFs
import app.lelvo.core.backup.UploadNames
import app.lelvo.core.crypto.FileCrypto
import app.lelvo.core.format.CaptionCodec
import app.lelvo.core.format.CaptionMeta
import app.lelvo.core.format.PartLayout
import app.lelvo.core.index.RemoteFile
import app.lelvo.core.support.AppLog
import app.lelvo.data.LibraryException
import app.lelvo.data.LibraryService
import app.lelvo.telegram.TdUploads
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import org.drinkless.tdlib.TdApi
import java.io.File
import java.io.InputStream
import java.security.DigestInputStream
import java.security.MessageDigest
import java.util.UUID
import kotlin.coroutines.coroutineContext

/** One file of an item to upload: the caption role, where its bytes come from and its caption (without `p`/`e`). */
class Resource(val role: String, val size: Long, val meta: CaptionMeta, val open: () -> InputStream)

/** Not enough free space for the part being uploaded: the user frees space first, so it isn't retried at once. */
class NotEnoughSpaceException(val needed: Long) : Exception(
    "Not enough free space to back up this item. Free up ${(needed + (1L shl 20) - 1) shr 20} MB and tap Retry.",
)

/** Telegram stored a part with a different size than was sent. */
class SizeMismatchException(expected: Long, actual: Long) : Exception("Telegram stored $actual bytes instead of $expected.")

/**
 * Uploads resources in format 1 (iOS `CloudUploader`), always CGFE-encrypted: split above the account limit, one
 * confirmed document message per part, and a size check before anything counts as uploaded. Only one part is on disk
 * at a time: the photo is encrypted straight from MediaStore into each part.
 */
class CloudUploader(
    private val uploads: TdUploads,
    private val library: LibraryService,
    private val staging: File,
) {
    /** Runs right before each part is sent (waits out a FLOOD_WAIT that started meanwhile). */
    var beforeSend: suspend () -> Unit = {}

    /**
     * Uploads [resource], skipping parts already confirmed in [existing]; an encrypted resume also needs [resume].
     * [checkpoint] runs after every confirmed part (parts, expected count, resume point), so progress survives the
     * app being killed.
     */
    suspend fun upload(
        itemId: String, resource: Resource, existing: List<RemoteFile>, resume: FileCrypto.ResumePoint?,
        checkpoint: suspend (List<RemoteFile>, Int, FileCrypto.ResumePoint?) -> Unit,
        progress: (Long, Long) -> Unit,
    ): List<RemoteFile> = withContext(Dispatchers.IO) {
        val chatId = library.chatId ?: throw LibraryException.notALibrary
        val keys = library.keys ?: throw LibraryException("Unlock your library to back up.")
        val chunk = if (resource.role == "sp") FileCrypto.FAST_VERSION_CHUNK_SIZE else FileCrypto.DEFAULT_CHUNK_SIZE
        val streamSize = FileCrypto.encryptedSize(resource.size, chunk)
        val layout = PartLayout.forUpload(streamSize, uploads.uploadLimit())

        var done = existing
        val matchesLayout = done.size <= layout.partCount && done.withIndex().all { (i, f) -> f.size == layout.sizeOfPart(i) }
        // Already complete (a retry after a later role failed): nothing to send again. iOS sends such a role again.
        if (matchesLayout && done.size == layout.partCount) return@withContext done

        val digest = MessageDigest.getInstance("SHA-256")
        val encryptor: FileCrypto.Encryptor
        if (done.isNotEmpty() && matchesLayout && resume != null &&
            resume.continues(done.map { it.size }, layout, chunk, resource.meta.h)
        ) {
            encryptor = FileCrypto.Encryptor.resuming(resource.open(), resource.size, keys.master, resume)
            AppLog.info("Resuming the upload of ${resource.role} at part ${done.size + 1} of ${layout.partCount}")
        } else {
            if (done.isNotEmpty()) {
                // No resume point that matches (the file or the account limit changed): start this file over. The old
                // parts must go first: a scan keeps the lowest message id of each part, so a stale part 1 would win.
                uploads.deleteMessages(chatId, done.map { it.messageId })
                done = emptyList()
                checkpoint(done, layout.partCount, null)
                AppLog.info("Starting the upload of ${resource.role} over: an earlier try can't be continued")
            }
            // Hashed as it's encrypted, to prove the bytes sent are the bytes the caption's hash describes.
            encryptor = FileCrypto.Encryptor(DigestInputStream(resource.open(), digest), resource.size, keys.master, chunk)
        }
        val fresh = done.isEmpty()

        val needed = layout.sizeOfPart(0) + UploadNames.SPACE_MARGIN
        staging.mkdirs()
        val free = runCatching { StatFs(staging.path).availableBytes }.getOrDefault(Long.MAX_VALUE)
        if (free < needed) throw NotEnoughSpaceException(needed - free)

        val work = File(staging, "up-${UUID.randomUUID()}").apply { mkdirs() }
        try {
            encryptor.use {
                for (index in done.size until layout.partCount) {
                    coroutineContext.ensureActive()
                    val partSize = layout.sizeOfPart(index)
                    val part = File(work, UploadNames.encrypted(itemId, resource.role, if (layout.isSplit) index else null))
                    write(partSize, encryptor, part)
                    val meta = resource.meta.copy(
                        p = if (layout.isSplit) listOf(index.toLong(), layout.partCount.toLong(), layout.partSize) else null,
                        e = 1, src = "android",
                    )
                    val caption = CaptionCodec.encode(meta, keys.captionKey)
                    val point = encryptor.resumePoint(resource.meta.h)
                    if (index == layout.partCount - 1 && fresh) {
                        val sent = PhoneFiles.hex(digest.digest())
                        if (sent != resource.meta.h) {
                            // Changed after it was hashed: the caption would describe other bytes. Nothing of it stays.
                            uploads.deleteMessages(chatId, done.map { f -> f.messageId })
                            checkpoint(emptyList(), layout.partCount, null)
                            throw FileChangedException()
                        }
                    }
                    beforeSend()
                    val base = index * layout.partSize
                    val message = uploads.sendDocument(chatId, part, caption) { sent, _ -> progress(base + sent, streamSize) }
                    val doc = (message.content as? TdApi.MessageDocument)?.document?.document
                    if (doc == null || doc.size != partSize) {
                        runCatching { uploads.deleteMessages(chatId, listOf(message.id)) }
                        throw SizeMismatchException(partSize, doc?.size ?: -1)
                    }
                    done = done + RemoteFile(message.id, doc.remote.id, doc.remote.uniqueId, doc.size)
                    checkpoint(done, layout.partCount, point)
                    // TDLib keeps the part as this file's local copy; it's deleted next, so reads must go to Telegram.
                    uploads.forgetLocalCopy(doc.id)
                    part.delete()
                    progress((index + 1) * layout.partSize, streamSize)
                }
            }
        } finally {
            work.deleteRecursively()
        }
        done
    }

    private fun write(length: Long, from: FileCrypto.Encryptor, to: File) {
        to.outputStream().buffered(1 shl 20).use { out ->
            var left = length
            while (left > 0) {
                val bytes = from.read(minOf(left, 4L shl 20).toInt())
                if (bytes.isEmpty()) throw FileChangedException()
                out.write(bytes)
                left -= bytes.size
            }
        }
    }
}
