package app.lelvo.data.backup

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.FrameDropEffect
import androidx.media3.effect.Presentation
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.EncoderUtil
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import app.lelvo.core.video.StreamingCopyPolicy
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.File
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** The video can't be converted at all (no decoder, unreadable): never tried again. */
class FastVersionUnsupported(message: String) : Exception(message)

/**
 * The fast version of a video, role `sp` (iOS `StreamingCopyEncoder`): HEVC at the policy's bitrate, at most 1920 px long and
 * 60 fps, standard colour, index first so it streams. Phones without an HEVC encoder get H.264. The rotation is applied, so the copy plays upright everywhere.
 */
@OptIn(UnstableApi::class)
object FastVersionEncoder {
    data class Result(val file: File, val width: Int, val height: Int, val codec: String)

    suspend fun encode(context: Context, source: Uri, out: File): Result {
        val (fps, shown) = withContext(Dispatchers.IO) { frameRate(context, source) to shownSize(context, source) }
        out.delete()
        val bitrate = StreamingCopyPolicy.targetBitsPerSecond(fps)
        val target = shown?.let { (w, h) -> val k = minOf(1f, 1920f / maxOf(w, h, 1)); even(w * k) to even(h * k) }
        // HEVC like iOS when an encoder takes the full size; otherwise H.264. A weak HEVC encoder (the emulator's
        // stops at 480p) made Media3 shrink the video to fit it.
        val mime = if (target == null || canEncode(MimeTypes.VIDEO_H265, target.first, target.second)) MimeTypes.VIDEO_H265 else MimeTypes.VIDEO_H264
        val video = EditedMediaItem.Builder(MediaItem.fromUri(source))
            .setEffects(Effects(emptyList(), buildList {
                // Slow-motion originals (120/240 fps) play at 60; 30 and 60 fps videos keep their own rate.
                if (fps > 60) add(FrameDropEffect.createDefaultFrameDropEffect(60f))
                // At most 1920 on the long side, as iOS: a 1080×2424 screen recording becomes 856×1920.
                target?.let { (w, h) -> add(Presentation.createForWidthAndHeight(w, h, Presentation.LAYOUT_SCALE_TO_FIT)) }
                    ?: add(Presentation.createForShortSide(1080))
            }))
            .build()
        val composition = Composition.Builder(EditedMediaItemSequence.withAudioAndVideoFrom(listOf(video)))
            .setHdrMode(Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL)
            .build()
        // Transformer must be built and started on a thread with a Looper; the work itself runs on its own threads.
        return withContext(Dispatchers.Main) {
            suspendCancellableCoroutine { cont ->
                val transformer = Transformer.Builder(context)
                    .setVideoMimeType(mime)
                    .setAudioMimeType(MimeTypes.AUDIO_AAC)
                    .setEncoderFactory(
                        DefaultEncoderFactory.Builder(context)
                            .setRequestedVideoEncoderSettings(VideoEncoderSettings.Builder().setBitrate(bitrate).build())
                            .setEnableFallback(true)
                            .build(),
                    )
                    .addListener(object : Transformer.Listener {
                        override fun onCompleted(composition: Composition, result: ExportResult) {
                            // Read back from the file: what the caption says (`wh`, `c`) must be what was written.
                            cont.resume(describe(context, out))
                        }

                        override fun onError(composition: Composition, result: ExportResult, e: ExportException) {
                            out.delete()
                            val unsupported = e.errorCode in listOf(
                                ExportException.ERROR_CODE_DECODER_INIT_FAILED, ExportException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED,
                                ExportException.ERROR_CODE_ENCODING_FORMAT_UNSUPPORTED,
                            )
                            app.lelvo.core.support.AppLog.warn("Fast version: Media3 ${e.errorCodeName}: ${e.cause?.let { it::class.simpleName + ": " + it.message?.take(160) } ?: ""}")
                            cont.resumeWithException(if (unsupported) FastVersionUnsupported(e.errorCodeName) else e)
                        }
                    })
                    .build()
                transformer.start(composition, out.path)
                cont.invokeOnCancellation {
                    // Cancel on the Looper thread Transformer was started on.
                    android.os.Handler(android.os.Looper.getMainLooper()).post { transformer.cancel(); out.delete() }
                }
            }
        }
    }

    private fun describe(context: Context, file: File): Result {
        val r = MediaMetadataRetriever()
        val (w, h) = try {
            r.setDataSource(file.path)
            val w = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
            val h = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
            val turned = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull()?.let { it == 90 || it == 270 } == true
            if (turned) h to w else w to h
        } finally { r.release() }
        val x = android.media.MediaExtractor()
        val mime = try {
            x.setDataSource(file.path)
            (0 until x.trackCount).map { x.getTrackFormat(it).getString(android.media.MediaFormat.KEY_MIME).orEmpty() }.firstOrNull { it.startsWith("video/") }
        } finally { x.release() }
        return Result(file, w, h, if (mime == MimeTypes.VIDEO_H265) "hevc" else "h264")
    }

    private fun canEncode(mime: String, w: Int, h: Int): Boolean = EncoderUtil.getSupportedEncoders(mime).any { info ->
        val caps = runCatching { info.getCapabilitiesForType(mime).videoCapabilities }.getOrNull() ?: return@any false
        caps.isSizeSupported(w, h) || caps.isSizeSupported(h, w)
    }

    private fun even(x: Float) = maxOf(2, (Math.round(x / 2f) * 2))

    /** Width and height as shown (rotation applied), or null when the file doesn't say. */
    private fun shownSize(context: Context, source: Uri): Pair<Int, Int>? = runCatching {
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(context, source)
            val w = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: return null
            val h = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: return null
            val turned = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull()?.let { it == 90 || it == 270 } == true
            if (turned) h to w else w to h
        } finally { r.release() }
    }.getOrNull()

    private fun frameRate(context: Context, source: Uri): Float = runCatching {
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(context, source)
            r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_CAPTURE_FRAMERATE)?.toFloatOrNull()
                ?: r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_FRAME_COUNT)?.toFloatOrNull()?.let { frames ->
                    r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toFloatOrNull()?.takeIf { it > 0 }?.let { frames / (it / 1000f) }
                }
        } finally { r.release() }
    }.getOrNull() ?: 30f
}
