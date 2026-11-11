package app.lelvo.android.media

import android.content.Context
import android.os.Build
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.DecoderCounters
import app.lelvo.core.support.AppLog

/** Which video decoders the players use, and what they report, so a stutter shows in the log as numbers. */
@OptIn(UnstableApi::class)
object VideoDecoders {
    /**
     * The Android emulator's own decoders (`goldfish`) hand decoding to the computer and break 4K HEVC: green and
     * purple blocks after a seek or a replay, and slow motion. On the emulator the players use Android's software
     * decoders instead; phones keep their hardware decoders.
     */
    private val emulator: Boolean =
        Build.HARDWARE.contains("ranchu") || Build.HARDWARE.contains("goldfish") || Build.PRODUCT.startsWith("sdk_gphone")

    fun renderers(context: Context): DefaultRenderersFactory = DefaultRenderersFactory(context)
        .setEnableDecoderFallback(true)
        .apply {
            if (emulator) setMediaCodecSelector { mime, secure, tunneling ->
                val all = MediaCodecSelector.DEFAULT.getDecoderInfos(mime, secure, tunneling)
                all.filterNot { it.name.contains("goldfish") }.ifEmpty { all }
            }
        }

    private val playable = java.util.concurrent.ConcurrentHashMap<String, Boolean>()

    /**
     * Whether this phone can play a video of this format and size: a decoder for it that takes the size, and, where
     * the phone publishes how fast its decoders are, one fast enough for [fps]. Phones differ a lot here (4K HEVC
     * plays on most phones from the last few years, not on older or low-end ones), so it's asked of each phone.
     * An unknown format counts as playable; the player then still falls back to another decoder if one fails.
     */
    fun canPlay(codec: String?, width: Int, height: Int, fps: Double = 30.0): Boolean {
        val mime = when (codec?.lowercase()) {
            "hevc", "h265", "hvc1", "hev1" -> android.media.MediaFormat.MIMETYPE_VIDEO_HEVC
            "h264", "avc", "avc1" -> android.media.MediaFormat.MIMETYPE_VIDEO_AVC
            else -> return true
        }
        if (width <= 0 || height <= 0) return true
        return playable.getOrPut("$mime $width $height $fps") {
            val ok = runCatching {
                android.media.MediaCodecList(android.media.MediaCodecList.REGULAR_CODECS).codecInfos.any { info ->
                    if (info.isEncoder || mime !in info.supportedTypes.map { it.lowercase() }) return@any false
                    if (emulator && info.name.contains("goldfish")) return@any false
                    val caps = info.getCapabilitiesForType(mime).videoCapabilities ?: return@any false
                    // Portrait videos are stored either way round; decoders often list only landscape sizes.
                    val (w, h) = if (caps.isSizeSupported(width, height)) width to height else if (caps.isSizeSupported(height, width)) height to width else return@any false
                    val points = if (Build.VERSION.SDK_INT >= 29) caps.supportedPerformancePoints else null
                    if (!points.isNullOrEmpty()) {
                        val wanted = android.media.MediaCodecInfo.VideoCapabilities.PerformancePoint(w, h, Math.round(fps).toInt())
                        points.any { it.covers(wanted) }
                    } else {
                        caps.areSizeAndRateSupported(w, h, fps)
                    }
                }
            }.getOrDefault(true)
            if (!ok) AppLog.info("Video: this phone can't play a ${minOf(width, height)}p $codec original smoothly; the fast version plays")
            ok
        }
    }

    /** Logs the decoder in use and, when a video closes, the frames it had to drop. */
    fun logging(what: () -> String): AnalyticsListener = object : AnalyticsListener {
        // Named when its decoder starts: by the time it stops, a quality switch has already named the next one.
        private var label = ""

        override fun onVideoDecoderInitialized(e: AnalyticsListener.EventTime, decoderName: String, initializedTimestampMs: Long, initializationDurationMs: Long) {
            label = what()
            AppLog.info("Video: $label decodes with $decoderName")
        }

        override fun onDroppedVideoFrames(e: AnalyticsListener.EventTime, droppedFrames: Int, elapsedMs: Long) {
            AppLog.warn("Video: $label dropped $droppedFrames frames in $elapsedMs ms")
        }

        override fun onVideoDisabled(e: AnalyticsListener.EventTime, counters: DecoderCounters) {
            if (counters.renderedOutputBufferCount > 0) {
                AppLog.info("Video: $label showed ${counters.renderedOutputBufferCount} frames, dropped ${counters.droppedBufferCount}")
            }
        }
    }
}
