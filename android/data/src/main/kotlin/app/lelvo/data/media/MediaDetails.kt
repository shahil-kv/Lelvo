package app.lelvo.data.media

import android.content.Context
import android.media.ExifInterface
import android.net.Uri
import android.provider.MediaStore
import app.lelvo.core.support.AppLog
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.InputStream

/** What the info sheet shows beyond the index: the file on the phone, the camera and the place, from the file itself. */
data class MediaDetails(
    val size: Long? = null,
    val folder: String? = null,
    val camera: String? = null,
    /** "ƒ/1.8 · 1/120 s · 6.9 mm · ISO 50", whatever the file has. */
    val exposure: String? = null,
    val latitude: Double? = null,
    val longitude: Double? = null,
)

/** Reads [MediaDetails] off the main thread. A file that can't be read gives empty details, never an error. */
class MediaDetailsReader(context: Context) {
    private val app = context.applicationContext

    /** A photo or video on this phone. The place needs "Allow access to location" (ACCESS_MEDIA_LOCATION). */
    suspend fun phone(uri: Uri, isVideo: Boolean): MediaDetails = withContext(Dispatchers.IO) {
        var size: Long? = null
        var folder: String? = null
        runCatching {
            app.contentResolver.query(uri, arrayOf(MediaStore.MediaColumns.SIZE, MediaStore.MediaColumns.RELATIVE_PATH), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    size = c.getLong(0).takeIf { it > 0 }
                    folder = c.getString(1)?.trimEnd('/')
                }
            }
        }
        if (isVideo) return@withContext MediaDetails(size, folder)
        // Without the original, Android removes the location from what an app reads.
        val original = runCatching { MediaStore.setRequireOriginal(uri) }.getOrDefault(uri)
        val exif = runCatching { app.contentResolver.openInputStream(original)?.use(::exif) }.getOrNull()
            ?: runCatching { app.contentResolver.openInputStream(uri)?.use(::exif) }.getOrNull()
        (exif ?: MediaDetails()).copy(size = size, folder = folder)
    }

    /** A cloud photo already downloaded to this phone. */
    suspend fun file(file: File): MediaDetails = withContext(Dispatchers.IO) {
        runCatching { file.inputStream().use(::exif) }.getOrNull() ?: MediaDetails()
    }

    private fun exif(stream: InputStream): MediaDetails? = try {
        val e = ExifInterface(stream)
        val make = e.getAttribute(ExifInterface.TAG_MAKE)?.trim()
        val model = e.getAttribute(ExifInterface.TAG_MODEL)?.trim()
        // "Apple iPhone 15 Pro" reads "iPhone 15 Pro": the model usually names the maker already.
        val camera = when {
            model.isNullOrEmpty() -> make?.takeIf { it.isNotEmpty() }
            make.isNullOrEmpty() || model.startsWith(make, ignoreCase = true) -> model
            make.equals("Apple", true) -> model
            else -> "$make $model"
        }
        val parts = buildList {
            e.getAttributeDouble(ExifInterface.TAG_F_NUMBER, 0.0).takeIf { it > 0 }?.let { add("ƒ/" + trim(it)) }
            e.getAttributeDouble(ExifInterface.TAG_EXPOSURE_TIME, 0.0).takeIf { it > 0 }?.let {
                add(if (it >= 1) "${trim(it)} s" else "1/${Math.round(1 / it)} s")
            }
            e.getAttributeDouble(ExifInterface.TAG_FOCAL_LENGTH, 0.0).takeIf { it > 0 }?.let { add("${trim(it)} mm") }
            @Suppress("DEPRECATION") e.getAttributeInt(ExifInterface.TAG_ISO_SPEED_RATINGS, 0).takeIf { it > 0 }?.let { add("ISO $it") }
        }
        val latLong = FloatArray(2).takeIf { e.getLatLong(it) }
        MediaDetails(
            camera = camera, exposure = parts.takeIf { it.isNotEmpty() }?.joinToString(" · "),
            latitude = latLong?.get(0)?.toDouble(), longitude = latLong?.get(1)?.toDouble(),
        )
    } catch (e: Exception) {
        AppLog.warn("Info: couldn't read the photo's details: ${e::class.simpleName}")
        null
    }

    private fun trim(v: Double): String = if (v == Math.floor(v)) v.toLong().toString() else "%.1f".format(v)
}
