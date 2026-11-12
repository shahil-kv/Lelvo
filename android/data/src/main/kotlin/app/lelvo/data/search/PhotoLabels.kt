package app.lelvo.data.search

import android.content.Context
import android.util.Size
import app.lelvo.core.index.PhoneAsset
import app.lelvo.core.support.AppLog
import app.lelvo.data.media.PhotoAccess
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.label.ImageLabeling
import com.google.mlkit.vision.label.defaults.ImageLabelerOptions
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.suspendCancellableCoroutine
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.Locale
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Things and scenes in each phone photo ("dog", "beach", "cake"), for search and themed Memories (iOS reads them
 * with Vision's `VNClassifyImageRequest`). ML Kit's bundled labeller runs on this phone, on a small thumbnail; no
 * photo or label leaves it (issue #117). Each photo is read once and again only when its file changes. The labels
 * stay in this phone's cache, never in the Telegram library: each device reads its own.
 */
internal class PhotoLabels(context: Context, private val photos: PhotoAccess, dir: File) {
    private val app = context.applicationContext
    private val file = File(dir, "labels.json")
    @Volatile private var cache: Map<String, Entry>? = null

    private data class Entry(val stamp: Long, val labels: List<String>)

    /** The labels of a phone photo, by MediaStore id; empty until it has been read. */
    fun of(localId: String): List<String> = load()[localId]?.labels.orEmpty()

    /**
     * Reads the photos in [assets] not read yet or changed since (videos are left out, as on iOS). Returns how many
     * were read. Stops when cancelled, keeping what it has: the next pass goes on from there.
     */
    suspend fun read(assets: List<PhoneAsset>, onProgress: (Int, Int) -> Unit = { _, _ -> }): Int {
        val known = HashMap(load())
        val present = assets.mapTo(HashSet()) { it.localId }
        val gone = known.keys.filter { it !in present }
        gone.forEach(known::remove)
        val todo = assets.filter { !it.isVideo && known[it.localId]?.stamp != (it.modifiedAt ?: 0) }
        if (todo.isEmpty()) { if (gone.isNotEmpty()) save(known); return 0 }
        val labeler = ImageLabeling.getClient(ImageLabelerOptions.Builder().setConfidenceThreshold(CONFIDENCE).build())
        val started = System.currentTimeMillis()
        var done = 0
        try {
            for (a in todo) {
                kotlin.coroutines.coroutineContext.ensureActive()
                val labels = runCatching {
                    val bitmap = app.contentResolver.loadThumbnail(photos.uri(a), Size(SIDE, SIDE), null)
                    try { label(labeler, bitmap) } finally { bitmap.recycle() }
                }.getOrElse { emptyList() }
                known[a.localId] = Entry(a.modifiedAt ?: 0, labels)
                done++
                onProgress(done, todo.size)
                // Saved as it goes, so a long first pass that is stopped keeps what it read.
                if (done % 50 == 0) save(known)
            }
        } finally {
            labeler.close()
            save(known)
            AppLog.info("Search index: read things in $done of ${todo.size} photos in ${(System.currentTimeMillis() - started) / 1000} s")
        }
        return done
    }

    fun clear() { cache = null; file.delete() }

    private suspend fun label(labeler: com.google.mlkit.vision.label.ImageLabeler, bitmap: android.graphics.Bitmap): List<String> =
        suspendCancellableCoroutine { cont ->
            labeler.process(InputImage.fromBitmap(bitmap, 0))
                .addOnSuccessListener { found ->
                    // ML Kit's names ("Christmas tree") written like Vision's identifiers ("christmas_tree"), the
                    // strongest ten, as iOS keeps.
                    cont.resume(found.sortedByDescending { it.confidence }.take(10).map { it.text.lowercase(Locale.ROOT).replace(' ', '_') })
                }
                .addOnFailureListener { cont.resumeWithException(it) }
        }

    private fun load(): Map<String, Entry> = cache ?: synchronized(this) {
        cache ?: runCatching {
            val o = JSONObject(file.readText())
            o.keys().asSequence().associateWith { k ->
                val a = o.getJSONArray(k)
                Entry(a.getLong(0), (1 until a.length()).map { a.getString(it) })
            }
        }.getOrDefault(emptyMap()).also { cache = it }
    }

    private fun save(known: Map<String, Entry>) {
        cache = HashMap(known)
        val o = JSONObject()
        for ((k, e) in known) o.put(k, JSONArray().put(e.stamp).apply { e.labels.forEach { put(it) } })
        file.parentFile?.mkdirs()
        val tmp = File(file.parentFile, file.name + ".tmp")
        tmp.writeText(o.toString())
        tmp.renameTo(file)
    }

    private companion object {
        /** ML Kit's own default is 0.5; a little higher keeps "Dogs" from catching a fluffy rug. */
        const val CONFIDENCE = 0.6f
        const val SIDE = 384
    }
}
