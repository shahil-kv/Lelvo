package app.lelvo.data.media

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import app.lelvo.core.support.AppLog
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext

/**
 * Photos and videos another app shares to Lelvo, turned into phone photos the backup engine already knows how to
 * upload. A file that is already in the phone's photos (shared from Gallery, Files or most chat apps) is used as it
 * is; only a file the phone doesn't have (a chat app's private copy, a cloud drive) is copied to `Pictures/Lelvo` or
 * `Movies/Lelvo` first, so it shows in the timeline and backs up like any other photo.
 */
class SharedIntake(context: Context) {
    private val app = context.applicationContext
    private val resolver get() = app.contentResolver

    data class Result(val localIds: List<String>, val copied: Int, val skipped: Int)

    /**
     * Must run while the sharing app's read grant is alive, so the caller keeps its activity open until this returns.
     * [progress] gets how many of [uris] are done.
     */
    suspend fun prepare(uris: List<Uri>, progress: (Int) -> Unit = {}): Result = withContext(Dispatchers.IO) {
        val ids = LinkedHashSet<String>()
        var copied = 0
        var skipped = 0
        uris.forEachIndexed { i, uri ->
            val id = runCatching { existingId(uri) ?: copy(uri)?.also { copied++ } }
                .onFailure { AppLog.warn("A shared file couldn't be added: ${it.javaClass.simpleName}") }
                .getOrNull()
            if (id == null) skipped++ else ids += id
            progress(i + 1)
        }
        AppLog.info("Shared to Lelvo: ${uris.size} file(s), ${ids.size} ready, $copied copied, $skipped skipped")
        Result(ids.toList(), copied, skipped)
    }

    fun isMedia(uri: Uri): Boolean = mimeOf(uri)?.let { it.startsWith("image/") || it.startsWith("video/") } ?: false

    /** The MediaStore id when the phone's photos already hold this file. */
    private fun existingId(uri: Uri): String? {
        if (uri.authority == MediaStore.AUTHORITY) {
            return runCatching { ContentUris.parseId(uri) }.getOrNull()?.takeIf { it > 0 }?.toString()
        }
        // Another app's provider hides the MediaStore id; the same name and byte size is the same file.
        val (name, size) = nameAndSize(uri) ?: return null
        if (name.isNullOrEmpty() || size <= 0) return null
        return resolver.query(
            MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL),
            arrayOf(MediaStore.Files.FileColumns._ID),
            "${MediaStore.MediaColumns.DISPLAY_NAME} = ? AND ${MediaStore.MediaColumns.SIZE} = ?",
            arrayOf(name, size.toString()), null,
        )?.use { c -> if (c.moveToFirst()) c.getLong(0).toString() else null }
    }

    private fun copy(uri: Uri): String? {
        val mime = mimeOf(uri) ?: return null
        val video = mime.startsWith("video/")
        if (!video && !mime.startsWith("image/")) return null
        // Room for the file plus a margin, so sharing never leaves the phone full.
        val size = nameAndSize(uri)?.second ?: -1L
        val free = android.os.Environment.getExternalStorageDirectory().usableSpace
        if (free < maxOf(size, 0L) + MARGIN) {
            AppLog.warn("A shared file wasn't saved: not enough space on the phone")
            return null
        }
        val name = nameAndSize(uri)?.first?.takeIf { it.isNotBlank() }
            ?: "Shared_${System.currentTimeMillis()}.${MimeTypeMap.getSingleton().getExtensionFromMimeType(mime) ?: if (video) "mp4" else "jpg"}"
        val collection = if (video) MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        else MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, if (video) "Movies/Lelvo" else "Pictures/Lelvo")
            // Hidden from other apps until the whole file is written.
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val target = resolver.insert(collection, values) ?: return null
        try {
            val wrote = resolver.openInputStream(uri)?.use { input ->
                resolver.openOutputStream(target)?.use { out -> input.copyTo(out, 1 shl 20); true }
            } ?: false
            if (!wrote) {
                resolver.delete(target, null, null)
                return null
            }
            resolver.update(target, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
        } catch (e: Throwable) {
            // A half-written file never shows up in the phone's photos.
            runCatching { resolver.delete(target, null, null) }
            throw e
        }
        return ContentUris.parseId(target).toString()
    }

    private fun mimeOf(uri: Uri): String? = resolver.getType(uri)
        ?: MimeTypeMap.getSingleton().getMimeTypeFromExtension(MimeTypeMap.getFileExtensionFromUrl(uri.toString()).lowercase())

    private fun nameAndSize(uri: Uri): Pair<String?, Long>? = runCatching {
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
            if (!c.moveToFirst()) null
            else (if (c.isNull(0)) null else c.getString(0)) to (if (c.isNull(1)) -1L else c.getLong(1))
        }
    }.getOrNull()

    private companion object { const val MARGIN = 500L shl 20 }
}
