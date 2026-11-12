package app.lelvo.data.backup

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.media.ExifInterface
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Size
import app.lelvo.core.backup.ScreenCopyPolicy
import app.lelvo.core.index.ItemKind
import app.lelvo.core.search.SearchMatcher
import app.lelvo.core.support.AppLog
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.security.MessageDigest

/** The phone file of an item to back up: what MediaStore says, plus what only the file itself knows. */
data class PhoneFile(
    val localId: String,
    val uri: Uri,
    val isVideo: Boolean,
    val filename: String,
    val mimeType: String?,
    val size: Long,
    /** `DATE_MODIFIED`, epoch ms: moves when the file is edited. */
    val modifiedAt: Long?,
    /** Capture time, epoch ms (`DATE_TAKEN`, else when it was added). */
    val createdAt: Long?,
    /** As shown: turned for photos stored sideways. */
    val width: Int,
    val height: Int,
    val duration: Double?,
    val isFavorite: Boolean,
    val bucketId: String?,
    val bucketName: String?,
    val relativePath: String?,
) {
    val kind: ItemKind get() = if (isVideo) ItemKind.Video else ItemKind.Photo
}

/** Android can't hand Lelvo the original file: the user hasn't allowed photo locations (`ACCESS_MEDIA_LOCATION`). */
class OriginalUnavailableException : Exception(
    "Lelvo needs to read where your photos were taken to back up the original files. Allow it in Settings → Apps → Lelvo → Permissions, then tap Retry.",
)

/** A photo whose file is no longer the size it was when its backup started. */
class FileChangedException : Exception("This photo changed while it was being backed up. It will be backed up again.")

/** Reading phone photos for a backup (iOS `PhotoLibraryService` export, thumbnail and screen copy parts). */
class PhoneFiles(context: Context) {
    private val app = context.applicationContext
    private val resolver = app.contentResolver

    private val columns = listOfNotNull(
        MediaStore.Files.FileColumns._ID, MediaStore.Files.FileColumns.MEDIA_TYPE, MediaStore.MediaColumns.DISPLAY_NAME,
        MediaStore.MediaColumns.MIME_TYPE, MediaStore.MediaColumns.SIZE, MediaStore.MediaColumns.DATE_MODIFIED,
        MediaStore.MediaColumns.DATE_TAKEN, MediaStore.MediaColumns.DATE_ADDED, MediaStore.MediaColumns.WIDTH,
        MediaStore.MediaColumns.HEIGHT, MediaStore.MediaColumns.DURATION, MediaStore.MediaColumns.BUCKET_ID,
        MediaStore.MediaColumns.BUCKET_DISPLAY_NAME, MediaStore.MediaColumns.RELATIVE_PATH,
        MediaStore.MediaColumns.ORIENTATION,
        if (Build.VERSION.SDK_INT >= 30) MediaStore.MediaColumns.IS_FAVORITE else null,
    ).toTypedArray()

    /** Every photo and video MediaStore lists, newest first. Empty without access. */
    fun all(): List<PhoneFile> = query(null, null)

    /** The files for these ids; ids missing from the result are gone from the phone. */
    fun files(localIds: Collection<String>): Map<String, PhoneFile> =
        localIds.chunked(500).flatMap { ids ->
            query("${MediaStore.Files.FileColumns._ID} IN (${ids.joinToString(",") { "?" }})", ids.toTypedArray())
        }.associateBy { it.localId }

    fun file(localId: String): PhoneFile? = files(listOf(localId))[localId]

    private fun query(extra: String?, args: Array<String>?): List<PhoneFile> {
        val out = ArrayList<PhoneFile>()
        val media = "${MediaStore.Files.FileColumns.MEDIA_TYPE} IN (${MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE}, ${MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO})"
        val where = if (extra == null) media else "$media AND $extra"
        runCatching {
            resolver.query(MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL), columns, where, args, null)?.use { c ->
                while (c.moveToNext()) {
                    val video = c.getInt(1) == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO
                    val id = c.getLong(0)
                    val w = c.getInt(8); val h = c.getInt(9)
                    val sideways = !video && c.getInt(14).let { it == 90 || it == 270 }
                    out += PhoneFile(
                        localId = id.toString(),
                        uri = ContentUris.withAppendedId(
                            if (video) MediaStore.Video.Media.EXTERNAL_CONTENT_URI else MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id,
                        ),
                        isVideo = video, filename = c.getString(2).orEmpty(), mimeType = c.getString(3), size = c.getLong(4),
                        modifiedAt = if (c.isNull(5)) null else c.getLong(5) * 1000,
                        createdAt = if (!c.isNull(6)) c.getLong(6) else if (!c.isNull(7)) c.getLong(7) * 1000 else null,
                        width = if (sideways) h else w, height = if (sideways) w else h,
                        duration = if (video && !c.isNull(10)) c.getLong(10) / 1000.0 else null,
                        bucketId = c.getString(11), bucketName = c.getString(12), relativePath = c.getString(13),
                        isFavorite = columns.size > 15 && c.getInt(15) == 1,
                    )
                }
            }
        }.onFailure { AppLog.error("Backup: listing phone photos failed: ${it::class.simpleName}") }
        return out.sortedByDescending { it.createdAt ?: Long.MIN_VALUE }
    }

    /**
     * The file's bytes exactly as stored. Without `setRequireOriginal` Android blanks the location in what an app reads,
     * and that copy must never be backed up as the original.
     */
    fun openOriginal(file: PhoneFile): InputStream {
        if (app.checkSelfPermission(Manifest.permission.ACCESS_MEDIA_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            throw OriginalUnavailableException()
        }
        val original = try { MediaStore.setRequireOriginal(file.uri) } catch (_: UnsupportedOperationException) { throw OriginalUnavailableException() }
        return try {
            resolver.openInputStream(original) ?: throw java.io.FileNotFoundException("No stream")
        } catch (_: SecurityException) {
            throw OriginalUnavailableException()
        }
    }

    /** SHA-256 (hex) and size of the original bytes. */
    fun hash(file: PhoneFile): Pair<String, Long> {
        val digest = MessageDigest.getInstance("SHA-256")
        var size = 0L
        openOriginal(file).use { s ->
            val buffer = ByteArray(1 shl 20)
            while (true) {
                val n = s.read(buffer)
                if (n < 0) break
                digest.update(buffer, 0, n)
                size += n
            }
        }
        return hex(digest.digest()) to size
    }

    /** Where it was taken, from the file (MediaStore hides it). Null when it has none. */
    fun location(file: PhoneFile): Pair<Double, Double>? = runCatching {
        val latLon = if (file.isVideo) {
            val r = MediaMetadataRetriever()
            try {
                r.setDataSource(app, MediaStore.setRequireOriginal(file.uri))
                r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_LOCATION)?.let(SearchMatcher::parseIso6709)
            } finally { r.release() }
        } else {
            openOriginal(file).use { s -> FloatArray(2).let { if (ExifInterface(s).getLatLong(it)) it[0].toDouble() to it[1].toDouble() else null } }
        }
        latLon?.takeIf { (lat, lon) -> !(lat == 0.0 && lon == 0.0) && lat in -90.0..90.0 && lon in -180.0..180.0 }
    }.getOrNull()

    /** The video's codec name as iOS writes it (`hevc`, `h264`…), when the file says. */
    fun videoCodec(file: PhoneFile): String? = runCatching {
        val x = MediaExtractor()
        try {
            x.setDataSource(app, file.uri, null)
            (0 until x.trackCount).map { x.getTrackFormat(it).getString(MediaFormat.KEY_MIME).orEmpty() }.firstOrNull { it.startsWith("video/") }
        } finally { x.release() }
    }.getOrNull()?.let {
        when (it) {
            MediaFormat.MIMETYPE_VIDEO_HEVC -> "hevc"
            MediaFormat.MIMETYPE_VIDEO_AVC -> "h264"
            MediaFormat.MIMETYPE_VIDEO_AV1 -> "av1"
            MediaFormat.MIMETYPE_VIDEO_VP9 -> "vp9"
            MediaFormat.MIMETYPE_VIDEO_DOLBY_VISION -> "dvh1"
            else -> null
        }
    }

    /**
     * A JPEG of at most 320 px on the long side and 60 KB (CLOUD_FORMAT.md §4, iOS `thumbnailJPEG`), with its pixel
     * size. Null when the phone can't make one.
     */
    fun thumbnail(file: PhoneFile): Triple<ByteArray, Int, Int>? {
        val bitmap = runCatching { resolver.loadThumbnail(file.uri, Size(THUMB, THUMB), null) }.getOrNull() ?: return null
        var side = THUMB.toFloat()
        while (side >= 80) {
            val scaled = fit(bitmap, side.toInt())
            for (quality in listOf(75, 60, 45, 30)) {
                val data = jpeg(scaled, quality)
                if (data.size <= THUMB_BYTES) return Triple(data, scaled.width, scaled.height)
            }
            side *= 0.8f
        }
        val last = fit(bitmap, 80)
        return Triple(jpeg(last, 30), last.width, last.height)
    }

    /**
     * The screen copy (role `d`): a JPEG at most 2048 px on the long side, turned the way the photo is shown. Throws
     * [ScreenCopyUnreadable] when the photo can't be decoded.
     */
    fun screenCopy(file: PhoneFile, into: File): Triple<File, Int, Int> {
        val bitmap = decodeForScreen(file) ?: throw ScreenCopyUnreadable()
        val scaled = fit(bitmap, ScreenCopyPolicy.MAX_PIXEL)
        into.outputStream().use { scaled.compress(Bitmap.CompressFormat.JPEG, ScreenCopyPolicy.JPEG_QUALITY, it) }
        return Triple(into, scaled.width, scaled.height)
    }

    private fun decodeForScreen(file: PhoneFile): Bitmap? {
        // ImageDecoder reads HEIC, DNG and the rest, turns the photo upright and only decodes what the size needs.
        runCatching {
            return ImageDecoder.decodeBitmap(ImageDecoder.createSource(resolver, file.uri)) { d, info, _ ->
                val long = maxOf(info.size.width, info.size.height)
                if (long > ScreenCopyPolicy.MAX_PIXEL) {
                    val scale = ScreenCopyPolicy.MAX_PIXEL.toFloat() / long
                    d.setTargetSize(maxOf(1, (info.size.width * scale).toInt()), maxOf(1, (info.size.height * scale).toInt()))
                }
                d.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            }
        }
        // Some HEIC files ImageDecoder refuses decode with BitmapFactory, which doesn't turn them: done by hand.
        return runCatching {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            resolver.openInputStream(file.uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
            var sample = 1
            while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= ScreenCopyPolicy.MAX_PIXEL) sample *= 2
            val decoded = resolver.openInputStream(file.uri)?.use { BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample }) }
                ?: return null
            val rotation = resolver.openInputStream(file.uri)?.use { when (ExifInterface(it).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
                ExifInterface.ORIENTATION_ROTATE_90 -> 90; ExifInterface.ORIENTATION_ROTATE_180 -> 180; ExifInterface.ORIENTATION_ROTATE_270 -> 270; else -> 0
            } } ?: 0
            if (rotation == 0) decoded else Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, Matrix().apply { postRotate(rotation.toFloat()) }, true)
        }.getOrNull()
    }

    private fun fit(b: Bitmap, maxPixel: Int): Bitmap {
        val long = maxOf(b.width, b.height)
        if (long <= maxPixel) return b
        val scale = maxPixel.toFloat() / long
        return Bitmap.createScaledBitmap(b, maxOf(1, (b.width * scale).toInt()), maxOf(1, (b.height * scale).toInt()), true)
    }

    private fun jpeg(b: Bitmap, quality: Int): ByteArray = ByteArrayOutputStream().also { b.compress(Bitmap.CompressFormat.JPEG, quality, it) }.toByteArray()

    companion object {
        const val THUMB = 320
        const val THUMB_BYTES = 60_000

        fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }
    }
}

class ScreenCopyUnreadable : Exception("This photo can't be made into a screen copy.")
