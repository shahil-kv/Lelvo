package app.lelvo.data.backup

import android.content.ContentUris
import android.content.Context
import android.os.Build
import android.provider.MediaStore
import app.lelvo.core.backup.SimilarPhotos
import app.lelvo.data.media.text
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Smart cleanup buckets (iOS `SmartCleanupService` #16C): screenshots, large videos, and a cheap burst teaser.
 * Exact Telegram/phone duplicates stay in [Duplicates]. Nothing is deleted here — the screen confirms.
 */
class SmartCleanupService(private val app: Context) {
    data class Item(val localId: String, val uri: android.net.Uri, val bytes: Long, val subtitle: String)

    data class Report(
        val screenshots: List<Item> = emptyList(),
        val largeVideos: List<Item> = emptyList(),
        val burstExtras: Int = 0,
        val burstBytes: Long = 0,
    ) {
        val proBytes: Long
            get() = screenshots.sumOf { it.bytes } + largeVideos.sumOf { it.bytes } + burstBytes
        val isEmpty: Boolean
            get() = screenshots.isEmpty() && largeVideos.isEmpty() && burstExtras == 0
    }

    companion object {
        const val LARGE_VIDEO_SECONDS = 90.0
        const val LARGE_VIDEO_BYTES = 50_000_000L
    }

    suspend fun scan(): Report = withContext(Dispatchers.IO) {
        val screenshots = ArrayList<Item>()
        val largeVideos = ArrayList<Item>()
        val sizes = HashMap<String, Long>()
        val candidates = ArrayList<SimilarPhotos.Candidate>()
        val uri = MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL)
        val columns = arrayOf(
            MediaStore.Files.FileColumns._ID,
            MediaStore.Files.FileColumns.MEDIA_TYPE,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.DURATION,
            MediaStore.MediaColumns.DATE_TAKEN,
            MediaStore.MediaColumns.DATE_ADDED,
            MediaStore.MediaColumns.BUCKET_DISPLAY_NAME,
            MediaStore.MediaColumns.WIDTH,
            MediaStore.MediaColumns.HEIGHT,
            if (Build.VERSION.SDK_INT >= 30) MediaStore.MediaColumns.IS_FAVORITE else MediaStore.MediaColumns.DATE_ADDED,
        )
        val where =
            "${MediaStore.Files.FileColumns.MEDIA_TYPE} IN (${MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE}, ${MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO})"
        app.contentResolver.query(uri, columns, where, null, null)?.use { c ->
            val iId = 0
            val iType = 1
            val iSize = 2
            val iDur = 3
            val iTaken = 4
            val iAdded = 5
            val iBucket = 6
            val iW = 7
            val iH = 8
            val iFav = 9
            while (c.moveToNext()) {
                val id = c.getLong(iId)
                val localId = id.toString()
                val bytes = c.getLong(iSize).coerceAtLeast(0)
                sizes[localId] = bytes
                val video = c.getInt(iType) == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO
                val contentUri = if (video) {
                    ContentUris.withAppendedId(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, id)
                } else {
                    ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id)
                }
                val bucket = c.text(iBucket)
                if (!video && bucket.equals("Screenshots", ignoreCase = true)) {
                    screenshots += Item(localId, contentUri, bytes, formatBytes(bytes))
                    continue
                }
                if (video) {
                    val durationMs = c.getLong(iDur)
                    val seconds = durationMs / 1000.0
                    if (seconds >= LARGE_VIDEO_SECONDS || bytes >= LARGE_VIDEO_BYTES) {
                        val clock = "%d:%02d".format((seconds / 60).toInt(), (seconds % 60).toInt())
                        largeVideos += Item(localId, contentUri, bytes, "$clock · ${formatBytes(bytes)}")
                    }
                    continue
                }
                val taken = c.getLong(iTaken).takeIf { it > 0 } ?: (c.getLong(iAdded) * 1000)
                val fav = Build.VERSION.SDK_INT >= 30 && c.getInt(iFav) == 1
                candidates += SimilarPhotos.Candidate(
                    localId, taken, c.getInt(iW).toLong() * c.getInt(iH), fav,
                )
            }
        }
        screenshots.sortByDescending { it.bytes }
        largeVideos.sortByDescending { it.bytes }
        var burstExtras = 0
        var burstBytes = 0L
        for (run in SimilarPhotos.runs(candidates)) {
            if (run.size < 2) continue
            val extras = run.drop(1)
            burstExtras += extras.size
            burstBytes += extras.sumOf { sizes[it.id] ?: 0L }
        }
        Report(screenshots, largeVideos, burstExtras, burstBytes)
    }

    private fun formatBytes(bytes: Long): String =
        android.text.format.Formatter.formatShortFileSize(app, bytes)
}
