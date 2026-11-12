package app.lelvo.data.media

import android.content.Context
import app.lelvo.core.cache.DiskCache
import app.lelvo.core.index.LibraryItem
import app.lelvo.core.support.AppLog
import app.lelvo.data.Prefs
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/**
 * Thumbnails and full-size photos of cloud items (iOS `CloudMediaService`): a 300 MB thumbnail cache and a capped
 * cache of viewed originals, both on disk. Videos stream instead.
 */
class CloudMedia(context: Context, private val reader: MediaReader, private val prefs: Prefs) {
    private val thumbnails = DiskCache(File(context.cacheDir, "Thumbnails")) { prefs.thumbnailCacheBytes }
    private val originals = DiskCache(File(context.cacheDir, "Originals")) { prefs.mediaCacheBytes }
    private val work = File(context.cacheDir, "Downloading").apply { mkdirs() }
    // More at once fills the grid faster but starves the photo being opened; iOS settled on 8.
    private val thumbnailGate = Semaphore(8)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val shared = ConcurrentHashMap<String, Deferred<File>>()

    fun cachedThumbnail(item: LibraryItem): File? = thumbnails.get("t_${item.id}", "jpg")

    /**
     * The item's thumbnail as a JPEG file. Runs in the caller: a tile scrolled away cancels its wait for a free
     * download slot, so what's on screen goes first.
     */
    suspend fun thumbnail(item: LibraryItem): File {
        cachedThumbnail(item)?.let { return it }
        reader.waitUntilReady()
        return thumbnailGate.withPermit {
            cachedThumbnail(item) ?: thumbnails.put("t_${item.id}", "jpg", reader.thumbnail(item))
        }
    }

    /** The role the viewer shows: Photos' rendered edit when the item has one, else the original. */
    fun displayedRole(item: LibraryItem): String = if (item.hasEdit && !item.parts["e"].isNullOrEmpty()) "e" else "o"

    private fun ext(item: LibraryItem, role: String): String {
        val name = when (role) { "e" -> item.editedName ?: item.filename; "d" -> "copy.jpg"; else -> item.filename }
        return name.substringAfterLast('.', "bin").lowercase().ifEmpty { "bin" }
    }

    fun hasScreenCopy(item: LibraryItem): Boolean = !item.parts["d"].isNullOrEmpty()

    /** The displayed photo if it's already on this phone (opening it needs no download). */
    fun cachedDisplayed(item: LibraryItem): File? = displayedRole(item).let { originals.get("o_${item.id}_$it", ext(item, it)) }

    /** Downloads (or returns the cached) photo the viewer shows: the edit, else the original. */
    suspend fun displayed(item: LibraryItem): File = file(item, displayedRole(item))

    /** The screen copy of a big photo (role `d`): a few hundred KB instead of up to 40 MB, shown while the original loads. */
    suspend fun screenCopy(item: LibraryItem): File = file(item, "d")

    /** One stored resource as a plaintext file, downloaded once even when the viewer and a prefetch ask together. */
    suspend fun file(item: LibraryItem, role: String): File {
        val key = "o_${item.id}_$role"
        val ext = ext(item, role)
        originals.get(key, ext)?.let { return it }
        val job = shared.computeIfAbsent(key) {
            // Started only once it's in the map, so a quick download can't remove itself before it was added.
            scope.async(start = CoroutineStart.LAZY) {
                try {
                    originals.get(key, ext) ?: run {
                        reader.waitUntilReady()
                        val started = System.currentTimeMillis()
                        val tmp = File(work, "${System.nanoTime()}.part")
                        try {
                            reader.download(item, role, tmp)
                            AppLog.info("Photo timing: role $role, ${tmp.length() shr 10} KB in ${System.currentTimeMillis() - started} ms")
                            originals.put(key, ext, tmp)
                        } finally {
                            tmp.delete()
                        }
                    }
                } finally {
                    shared.remove(key)
                }
            }
        }
        job.start()
        return job.await()
    }

    /** Neighbouring photos are fetched ahead only up to this size (RAW and the like would cost too much data). */
    suspend fun prefetch(item: LibraryItem) {
        if (cachedDisplayed(item) != null) return
        runCatching {
            if (hasScreenCopy(item)) screenCopy(item) else if (item.fileSize <= PREFETCH_LIMIT) displayed(item)
        }
    }

    val cacheBytes: Long get() = thumbnails.totalBytes + originals.totalBytes

    /** Settings → Storage: what each cache holds on this phone. Reads folders, so call it off the main thread. */
    data class Usage(val thumbnails: Long, val originals: Long, val telegram: Long) { val total get() = thumbnails + originals + telegram }

    suspend fun usage(): Usage = Usage(thumbnails.totalBytes, originals.totalBytes, reader.telegramStorageBytes())

    /** Every cache within its limit, TDLib's own file cache too (iOS `enforceCacheLimits`); at launch and on a change. */
    suspend fun enforceLimits() {
        thumbnails.trimToCapacity()
        originals.trimToCapacity()
        reader.trimTelegramFiles(prefs.mediaCacheBytes)
    }

    fun clear() {
        thumbnails.clear()
        originals.clear()
        reader.forgetCaches()
    }

    /** Settings → Storage → Clear: the caches here and every file TDLib downloaded. Photos and the backup stay. */
    suspend fun clearAll() {
        clear()
        reader.clearTelegramFiles()
        val left = usage()
        AppLog.info("Cleared caches: ${left.total shr 10} KB left (thumbnails ${left.thumbnails shr 10} KB, viewed ${left.originals shr 10} KB, Telegram ${left.telegram shr 10} KB)")
    }

    private companion object { const val PREFETCH_LIMIT = 15L shl 20 }
}
