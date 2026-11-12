package app.lelvo.data.backup

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Size
import app.lelvo.core.backup.PerceptualHash
import app.lelvo.core.backup.SimilarPhotos
import app.lelvo.core.index.Gallery
import app.lelvo.core.index.GalleryEntry
import app.lelvo.core.support.AppLog
import app.lelvo.data.index.LibraryStore
import app.lelvo.data.media.CloudMedia
import app.lelvo.data.media.PhotoAccess
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/**
 * Finds near-identical photos (bursts, several shots of one thing) for Duplicates review (iOS `SimilarPhotosService`).
 * Like iOS, the whole library is compared: photos on this phone from Android's own small thumbnail, cloud-only ones
 * from their backup thumbnail. Nothing leaves the phone. Hashes are kept in the cache folder per photo version, so
 * looking again only reads new photos.
 */
class SimilarPhotosService(
    context: Context,
    private val store: LibraryStore,
    private val photos: PhotoAccess,
    private val media: CloudMedia,
) {
    data class Group(val entries: List<GalleryEntry>, val best: String) {
        val id: String get() = entries.firstOrNull()?.id ?: best
    }

    private val resolver = context.applicationContext.contentResolver
    private val cacheFile = File(context.applicationContext.cacheDir, "similar-hashes.txt")
    private val hashes = ConcurrentHashMap<String, Long>()
    @Volatile private var hashesLoaded = false
    // One pass at a time: asking again while one runs waits for it, then finds everything already hashed.
    private val running = Mutex()

    /**
     * Groups of similar photos, newest first. [progress] reports (compared, to compare) every few photos. Runs in the
     * caller, so leaving the screen stops it.
     */
    suspend fun find(progress: (Int, Int) -> Unit): List<Group> = running.withLock {
        withContext(Dispatchers.Default) { compare(progress) }
    }

    private suspend fun compare(progress: (Int, Int) -> Unit): List<Group> {
        val started = System.currentTimeMillis()
        val items = store.items().first()
        val entries = Gallery.merge(photos.assets(), items, store.aliases())
            .filter { e -> !e.isVideo && e.date != null && !(e.asset?.bucketName.equals("Screenshots", ignoreCase = true)) }
            .associateBy { it.id }
        // Photo versions: an edited phone photo is read again.
        val versions = entries.mapValues { (id, e) -> e.asset?.let { "${it.localId}|${it.modifiedAt ?: 0}" } ?: id }
        val candidates = entries.values.map { e ->
            val pixels = e.asset?.let { it.width.toLong() * it.height } ?: e.item?.let { it.width.toLong() * it.height } ?: 0L
            SimilarPhotos.Candidate(e.id, e.date!!, pixels, e.isFavorite)
        }
        val runs = SimilarPhotos.runs(candidates)
        val total = runs.sumOf { it.size }
        withContext(Dispatchers.IO) { loadHashes() }
        progress(0, total)
        var done = 0
        var computed = 0
        val groups = ArrayList<Group>()
        for (run in runs) {
            if (!currentCoroutineContext().isActive) break
            val runHashes = HashMap<String, Long>()
            for (c in run) {
                val entry = entries[c.id] ?: continue
                val version = versions.getValue(c.id)
                val known = hashes[version]
                if (known != null) {
                    runHashes[c.id] = known
                } else {
                    hash(entry)?.let { h ->
                        hashes[version] = h
                        runHashes[c.id] = h
                        computed++
                    }
                }
                done++
                if (done % 10 == 0 || done == total) progress(done, total)
            }
            for (g in SimilarPhotos.groups(run) { a, b ->
                val x = runHashes[a.id]; val y = runHashes[b.id]
                x != null && y != null && PerceptualHash.close(x, y)
            }) {
                val best = SimilarPhotos.best(g) ?: continue
                groups += Group(g.mapNotNull { entries[it.id] }, best.id)
            }
        }
        // Only photos that can still be compared keep a hash: deleted and edited ones drop out.
        val current = runs.flatten().mapNotNull { versions[it.id] }.toSet()
        val before = hashes.size
        hashes.keys.retainAll(current)
        if (computed > 0 || hashes.size != before) withContext(Dispatchers.IO) { saveHashes() }
        AppLog.info("Similar photos: ${groups.size} groups among $total candidates of ${candidates.size} photos " +
            "($computed read now) in ${"%.1f".format((System.currentTimeMillis() - started) / 1000.0)} s")
        return groups.reversed()
    }

    /** The hash of a small image: Android's thumbnail of a phone photo, else the backup's thumbnail. */
    private suspend fun hash(entry: GalleryEntry): Long? = try {
        val bitmap = withContext(Dispatchers.IO) {
            entry.asset?.let { resolver.loadThumbnail(photos.uri(it), Size(256, 256), null) }
                ?: entry.item?.let { item -> decodeSmall(media.thumbnail(item)) }
        }
        bitmap?.let(::hashOf)
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        // A photo that can't be read (gone, offline, not decodable) just isn't compared.
        null
    }

    private fun decodeSmall(file: File): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        var sample = 1
        while (bounds.outWidth / (sample * 2) >= 128 && bounds.outHeight / (sample * 2) >= 128) sample *= 2
        return BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = sample })
    }

    private fun hashOf(bitmap: Bitmap): Long {
        val side = PerceptualHash.SIDE
        // Stretched to a square like iOS (`scaleFill`): two shots of one scene keep the same layout.
        val small = Bitmap.createScaledBitmap(bitmap, side, side, true)
        val pixels = IntArray(side * side)
        small.getPixels(pixels, 0, side, 0, 0, side, side)
        if (small !== bitmap) small.recycle()
        bitmap.recycle()
        val grey = IntArray(pixels.size) { i ->
            val p = pixels[i]
            (299 * (p shr 16 and 0xff) + 587 * (p shr 8 and 0xff) + 114 * (p and 0xff)) / 1000
        }
        return PerceptualHash.of(grey)
    }

    private fun loadHashes() {
        if (hashesLoaded) return
        hashesLoaded = true
        runCatching {
            if (!cacheFile.exists()) return
            cacheFile.forEachLine { line ->
                val tab = line.lastIndexOf('\t')
                if (tab > 0) line.substring(tab + 1).toULongOrNull(16)?.toLong()?.let { hashes[line.substring(0, tab)] = it }
            }
        }
    }

    private fun saveHashes() {
        runCatching {
            val tmp = File(cacheFile.path + ".tmp")
            tmp.bufferedWriter().use { w -> for ((k, v) in hashes) { w.write(k); w.write("\t"); w.write(java.lang.Long.toHexString(v)); w.newLine() } }
            tmp.renameTo(cacheFile)
        }
    }
}
