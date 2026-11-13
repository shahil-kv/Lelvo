package app.lelvo.data.media

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import app.lelvo.core.index.ItemKind
import app.lelvo.core.index.LibraryItem
import app.lelvo.core.support.AppLog
import app.lelvo.data.index.LibraryStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import java.io.File

/** What the user reads when saving to the phone fails (the iOS "Couldn't save" alert texts). */
class SaveException(message: String) : Exception(message)

/**
 * Saves a cloud item's original to this phone's photos (iOS `GalleryActions.saveToPhotos`): downloaded and decrypted
 * whole, written to `Pictures/Lelvo` or `Movies/Lelvo` with its capture date, then linked to the item, so the timeline
 * shows one tile that is on the phone and in the cloud.
 *
 * Android keeps no edit beside an original and has no Live Photos, so the untouched original is saved, without its
 * edit or paired video (iOS restores both through `RestorePlan`).
 */
class PhoneSaver(context: Context, private val reader: MediaReader, private val store: LibraryStore) {
    private val app = context.applicationContext
    private val work = File(app.cacheDir, "Saving")

    /** Returns the new MediaStore id. [progress] runs from 0 to 1 while the original downloads. */
    suspend fun save(item: LibraryItem, progress: (Float) -> Unit): String = withContext(Dispatchers.IO) {
        reader.waitUntilReady()
        val size = reader.plaintextSize(item, "o")
        // Room for the download and the copy in Photos at once, plus a margin so the phone isn't left full.
        if (app.cacheDir.usableSpace < size * 2 + MARGIN) {
            throw SaveException("There isn't enough space on this phone. Free up some space and try again.")
        }
        work.mkdirs()
        val tmp = File(work, "${System.nanoTime()}.part")
        val started = System.currentTimeMillis()
        try {
            reader.download(item, "o", tmp, progress)
            val took = (System.currentTimeMillis() - started) / 1000.0
            AppLog.info("Downloaded an original to save: ${size shr 10} KB in ${"%.0f".format(took)} s")
            insert(item, tmp)
        } finally {
            tmp.delete()
        }
    }

    private suspend fun insert(item: LibraryItem, file: File): String {
        val video = item.kind == ItemKind.Video
        val collection = if (video) MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        else MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val ext = item.filename.substringAfterLast('.', "").lowercase()
        val mime = item.mimeType ?: MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: if (video) "video/mp4" else "image/jpeg"
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, item.filename.ifEmpty { if (video) "video.mp4" else "photo.jpg" })
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, if (video) "Movies/Lelvo" else "Pictures/Lelvo")
            item.createdAt?.let { put(MediaStore.MediaColumns.DATE_TAKEN, it) }
            // Hidden from other apps until the whole file is written.
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val resolver = app.contentResolver
        val uri = resolver.insert(collection, values) ?: throw SaveException("Couldn't save to this phone's photos. Try again.")
        try {
            resolver.openOutputStream(uri)?.use { out -> file.inputStream().use { it.copyTo(out, 1 shl 20) } }
                ?: throw SaveException("Couldn't save to this phone's photos. Try again.")
            // Publishing rescans the file and takes the date from its EXIF; a file without one (screenshots, photos
            // from chat apps) was left with none and showed under Today. The capture date from the backup goes in the
            // same update.
            resolver.update(
                uri,
                ContentValues().apply {
                    put(MediaStore.MediaColumns.IS_PENDING, 0)
                    item.createdAt?.let { put(MediaStore.MediaColumns.DATE_TAKEN, it) }
                },
                null, null,
            )
            item.createdAt?.let { taken ->
                val stored = resolver.query(uri, arrayOf(MediaStore.MediaColumns.DATE_TAKEN), null, null, null)?.use { c ->
                    if (c.moveToFirst() && !c.isNull(0)) c.getLong(0) else null
                }
                AppLog.info("Saved to the phone: capture date ${if (stored == taken) "kept" else if (stored == null) "missing" else "from the file"}")
            }
        } catch (e: Throwable) {
            // A half-written file never shows up in the phone's photos.
            withContext(NonCancellable) { runCatching { resolver.delete(uri, null, null) } }
            throw e
        }
        val id = ContentUris.parseId(uri).toString()
        store.item(item.id)?.let { store.upsert(listOf(it.copy(localId = id))) }
        return id
    }

    private companion object { const val MARGIN = 200L shl 20 }
}
