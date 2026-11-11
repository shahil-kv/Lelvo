package app.lelvo.data.media

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.provider.MediaStore
import android.util.Size
import app.lelvo.core.support.AppLog
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Access to the phone's photos, the Android side of the iPhone's `PHAuthorizationStatus`. Android 14+ has partial
 * access ("Allow limited access"), like the iPhone's Limited; Android 10–12 ask for storage instead.
 */
class PhotoAccess(context: Context) {
    private val app = context.applicationContext
    // Not in the settings file on purpose: Android itself remembers a denial across a sign-out, so this must too.
    private val prefs = app.getSharedPreferences("photos", Context.MODE_PRIVATE)

    enum class Status { NotAsked, Full, Partial, Denied }

    /** The permissions to ask for, in one system prompt. */
    val permissions: Array<String> = when {
        Build.VERSION.SDK_INT >= 34 -> arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO,
            Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED, Manifest.permission.ACCESS_MEDIA_LOCATION)
        Build.VERSION.SDK_INT >= 33 -> arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO,
            Manifest.permission.ACCESS_MEDIA_LOCATION)
        else -> arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE, Manifest.permission.ACCESS_MEDIA_LOCATION)
    }

    fun status(): Status {
        fun has(p: String) = app.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED
        val full = if (Build.VERSION.SDK_INT >= 33) has(Manifest.permission.READ_MEDIA_IMAGES) && has(Manifest.permission.READ_MEDIA_VIDEO)
        else has(Manifest.permission.READ_EXTERNAL_STORAGE)
        return when {
            full -> Status.Full
            Build.VERSION.SDK_INT >= 34 && has(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED) -> Status.Partial
            prefs.getBoolean(ASKED, false) -> Status.Denied
            else -> Status.NotAsked
        }
    }

    /** Called after the system prompt closes, whatever the answer. */
    fun markAsked(): Status {
        prefs.edit().putBoolean(ASKED, true).apply()
        return status().also { AppLog.info("Photos access: $it") }
    }

    data class Stats(val items: Int, val bytes: Long, val free: Long)

    /** How many photos and videos this phone has (or shared with Lelvo), their size, and the free space. */
    suspend fun stats(): Stats = withContext(Dispatchers.IO) {
        var items = 0
        var bytes = 0L
        for (uri in listOf(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, MediaStore.Video.Media.EXTERNAL_CONTENT_URI)) {
            runCatching {
                app.contentResolver.query(uri, arrayOf(MediaStore.MediaColumns.SIZE), null, null, null)?.use { c ->
                    while (c.moveToNext()) { items++; bytes += c.getLong(0) }
                }
            }.onFailure { AppLog.error("Photos: count failed: ${it::class.simpleName}") }
        }
        val free = runCatching { StatFs(Environment.getDataDirectory().path).availableBytes }.getOrDefault(0L)
        AppLog.info("Intro: library has $items items, ${bytes shr 20} MB")
        Stats(items, bytes, free)
    }

    /** Thumbnails of the newest photos, newest first. */
    suspend fun recent(limit: Int, size: Int): List<Bitmap> = withContext(Dispatchers.IO) {
        val ids = mutableListOf<Long>()
        runCatching {
            app.contentResolver.query(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, arrayOf(MediaStore.Images.Media._ID),
                null, null, "${MediaStore.Images.Media.DATE_ADDED} DESC")?.use { c ->
                while (c.moveToNext() && ids.size < limit) ids += c.getLong(0)
            }
        }
        ids.mapNotNull { id ->
            val uri = ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id)
            runCatching { app.contentResolver.loadThumbnail(uri, Size(size, size), null) }.getOrNull()
        }
    }

    private companion object { const val ASKED = "asked" }
}
