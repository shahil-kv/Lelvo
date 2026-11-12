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
import app.lelvo.core.index.AssetKey
import app.lelvo.core.index.PhoneAsset
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.flow.flow
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

    /**
     * Every photo and video this app can see, as linking needs them: MediaStore id (images and videos share one id
     * space), file name, capture time and the size as shown (turned photos swap width and height, like Photos' size).
     */
    suspend fun assetKeys(): List<AssetKey> = withContext(Dispatchers.IO) {
        val out = ArrayList<AssetKey>()
        val orientation = if (Build.VERSION.SDK_INT >= 30) MediaStore.MediaColumns.ORIENTATION else null
        for ((uri, turned) in listOf(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI to (orientation ?: MediaStore.Images.ImageColumns.ORIENTATION),
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI to orientation,
        )) {
            val columns = listOfNotNull(MediaStore.MediaColumns._ID, MediaStore.MediaColumns.DISPLAY_NAME, MediaStore.MediaColumns.DATE_TAKEN,
                MediaStore.MediaColumns.WIDTH, MediaStore.MediaColumns.HEIGHT, turned).toTypedArray()
            runCatching {
                app.contentResolver.query(uri, columns, null, null, null)?.use { c ->
                    while (c.moveToNext()) {
                        val w = c.getInt(3); val h = c.getInt(4)
                        val sideways = turned != null && c.getInt(5).let { it == 90 || it == 270 }
                        out += AssetKey(
                            localId = c.getLong(0).toString(), filename = c.getString(1).orEmpty(),
                            takenAt = if (c.isNull(2)) null else c.getLong(2),
                            width = if (sideways) h else w, height = if (sideways) w else h,
                        )
                    }
                }
            }.onFailure { AppLog.error("Photos: listing failed: ${it::class.simpleName}") }
        }
        out
    }

    /**
     * This phone's photos and videos for the timeline, newest first: by the capture date when the file has one, else
     * when it was added (`Gallery.merge` may use the backup's date for those). Empty without access.
     */
    suspend fun assets(): List<PhoneAsset> = withContext(Dispatchers.IO) {
        val status = status()
        if (status != Status.Full && status != Status.Partial) return@withContext emptyList()
        val out = ArrayList<PhoneAsset>()
        val uri = MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL)
        val favorite = if (Build.VERSION.SDK_INT >= 30) MediaStore.MediaColumns.IS_FAVORITE else null
        val columns = listOfNotNull(
            MediaStore.Files.FileColumns._ID, MediaStore.Files.FileColumns.MEDIA_TYPE, MediaStore.MediaColumns.DATE_TAKEN,
            MediaStore.MediaColumns.DATE_ADDED, MediaStore.MediaColumns.DURATION, MediaStore.MediaColumns.WIDTH,
            MediaStore.MediaColumns.HEIGHT, MediaStore.MediaColumns.DISPLAY_NAME, MediaStore.MediaColumns.BUCKET_ID,
            MediaStore.MediaColumns.BUCKET_DISPLAY_NAME, MediaStore.MediaColumns.DATE_MODIFIED, favorite,
        ).toTypedArray()
        val where = "${MediaStore.Files.FileColumns.MEDIA_TYPE} IN (${MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE}, ${MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO})"
        runCatching {
            app.contentResolver.query(uri, columns, where, null, null)?.use { c ->
                while (c.moveToNext()) {
                    val video = c.getInt(1) == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO
                    val taken = if (c.isNull(2)) null else c.getLong(2)
                    out += PhoneAsset(
                        localId = c.getLong(0).toString(), takenAt = taken, isVideo = video,
                        duration = if (video && !c.isNull(4)) c.getLong(4) / 1000.0 else null,
                        width = c.getInt(5), height = c.getInt(6), filename = c.getString(7).orEmpty(),
                        isFavorite = favorite != null && c.getInt(11) == 1, addedAt = c.getLong(3) * 1000,
                        bucketId = c.getString(8), bucketName = c.getString(9), modifiedAt = c.getLong(10),
                    )
                }
            }
        }.onFailure { AppLog.error("Photos: timeline listing failed: ${it::class.simpleName}") }
        out.sortByDescending { it.takenAt ?: it.addedAt ?: Long.MIN_VALUE }
        out
    }

    /**
     * MediaStore ids of every favorite on this phone (iOS `favoriteIdentifiers`), in one query however big the
     * library. Null without full access or before Android 11: with partial access, photos Lelvo can't see would look
     * unfavorited. A query that fails is null too, never "none are favorites".
     */
    suspend fun favoriteIds(): Set<String>? = withContext(Dispatchers.IO) {
        if (Build.VERSION.SDK_INT < 30 || status() != Status.Full) return@withContext null
        runCatching {
            val out = HashSet<String>()
            app.contentResolver.query(
                MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL), arrayOf(MediaStore.Files.FileColumns._ID),
                "${MediaStore.MediaColumns.IS_FAVORITE} = 1", null, null,
            )?.use { c -> while (c.moveToNext()) out += c.getLong(0).toString() } ?: return@runCatching null
            out
        }.onFailure { AppLog.warn("Photos: favorites query failed: ${it::class.simpleName}") }.getOrNull()
    }

    /** The favorite of each of these photos still on the phone, read again right before acting on it. */
    suspend fun favorites(localIds: Collection<String>): Map<String, Boolean> = withContext(Dispatchers.IO) {
        if (Build.VERSION.SDK_INT < 30 || localIds.isEmpty()) return@withContext emptyMap()
        val out = HashMap<String, Boolean>()
        localIds.chunked(500).forEach { chunk ->
            runCatching {
                app.contentResolver.query(
                    MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL),
                    arrayOf(MediaStore.Files.FileColumns._ID, MediaStore.MediaColumns.IS_FAVORITE),
                    "${MediaStore.Files.FileColumns._ID} IN (${chunk.joinToString(",") { "?" }})", chunk.toTypedArray(), null,
                )?.use { c -> while (c.moveToNext()) out[c.getLong(0).toString()] = c.getInt(1) == 1 }
            }
        }
        out
    }

    /** Content Uris by MediaStore id, for the system's favorite prompt (photo or video decided by MediaStore). */
    suspend fun uris(localIds: Collection<String>): List<android.net.Uri> = withContext(Dispatchers.IO) {
        val out = ArrayList<android.net.Uri>()
        localIds.chunked(500).forEach { chunk ->
            runCatching {
                app.contentResolver.query(
                    MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL),
                    arrayOf(MediaStore.Files.FileColumns._ID, MediaStore.Files.FileColumns.MEDIA_TYPE),
                    "${MediaStore.Files.FileColumns._ID} IN (${chunk.joinToString(",") { "?" }})", chunk.toTypedArray(), null,
                )?.use { c ->
                    while (c.moveToNext()) {
                        val video = c.getInt(1) == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO
                        out += ContentUris.withAppendedId(
                            if (video) MediaStore.Video.Media.EXTERNAL_CONTENT_URI else MediaStore.Images.Media.EXTERNAL_CONTENT_URI, c.getLong(0),
                        )
                    }
                }
            }
        }
        out
    }

    /** The content Uri of a phone photo or video, for thumbnails, the viewer, sharing and deleting. */
    fun uri(asset: PhoneAsset): android.net.Uri = ContentUris.withAppendedId(
        if (asset.isVideo) MediaStore.Video.Media.EXTERNAL_CONTENT_URI else MediaStore.Images.Media.EXTERNAL_CONTENT_URI, asset.localId.toLong(),
    )

    /** Emits once at start and again (at most every 1.5 s) when photos are added, removed or changed. */
    fun changes(): Flow<Unit> = callbackFlow {
        val observer = object : android.database.ContentObserver(android.os.Handler(android.os.Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) { trySend(Unit) }
        }
        app.contentResolver.registerContentObserver(MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL), true, observer)
        trySend(Unit)
        awaitClose { app.contentResolver.unregisterContentObserver(observer) }
    }.conflate().throttle(1_500)

    private companion object { const val ASKED = "asked" }
}

/** Like iOS's throttled timeline reload: the first change shows at once, later ones at most every [ms]. */
private fun Flow<Unit>.throttle(ms: Long): Flow<Unit> = flow {
    var last = 0L
    collect {
        val wait = last + ms - System.currentTimeMillis()
        if (wait > 0) kotlinx.coroutines.delay(wait)
        last = System.currentTimeMillis()
        emit(Unit)
    }
}
