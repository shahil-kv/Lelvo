package app.lelvo.core.video

/** Moving around a video in the viewer (iOS `VideoNavigation`). */
object VideoNavigation {
    /** Seconds a double-tap on either side skips. */
    const val SKIP = 10.0

    /** Only videos at least this long remember where they were left, like Photos. */
    const val RESUME_MINIMUM_DURATION = 120.0

    fun skipTarget(current: Double, duration: Double, by: Double): Double {
        val now = if (current.isFinite()) current else 0.0
        if (!duration.isFinite() || duration <= 0) return maxOf(0.0, now + by)
        return (now + by).coerceIn(0.0, duration)
    }

    /** A long video, past its first seconds and not at its end. */
    fun shouldRemember(position: Double, duration: Double): Boolean {
        if (!duration.isFinite() || !position.isFinite() || duration < RESUME_MINIMUM_DURATION) return false
        return position >= 10 && position < duration - maxOf(10.0, duration * 0.05)
    }

    /** [count] times spread evenly along the video, each in the middle of its slice, for the frame strip. */
    fun stripTimes(duration: Double, count: Int): List<Double> {
        if (!duration.isFinite() || duration <= 0 || count <= 0) return emptyList()
        val slice = duration / count
        return (0 until count).map { (it + 0.5) * slice }
    }

    /** Where to start a video last left at [saved]; null starts from the beginning. */
    fun resumePosition(saved: Double?, duration: Double): Double? = saved?.takeIf { shouldRemember(it, duration) }
}

/** Which stored version of a cloud video plays (iOS `VideoQuality`). */
enum class VideoVersion { Original, Fast }

/** The user's setting: the same values as the iOS one, plus Android's "Fast", which always picks the fast version. */
enum class VideoPreference { Automatic, Original, Fast }

/** Picks the version a cloud video opens with, and when to fall back to the fast one (iOS `VideoQualityPolicy`). */
object VideoQualityPolicy {
    /** The original paused to load for this long while playing: switch to the fast version (Automatic only). */
    const val STALL_SECONDS_BEFORE_FALLBACK = 3.0

    /**
     * Automatic always starts on the fast version when there is one: it plays at once on any connection (Telegram
     * sends about 1 MB/s; phone videos need 2–8), and the viewer can switch to the original. An original this phone
     * can't decode smoothly ([originalPlayable] false: a 4K HEVC video on an older phone) never plays first, whatever
     * the setting, when there's a fast version to play instead.
     */
    fun initial(preference: VideoPreference, hasFast: Boolean, originalPlayable: Boolean = true): VideoVersion =
        if (hasFast && (preference != VideoPreference.Original || !originalPlayable)) VideoVersion.Fast else VideoVersion.Original

    /** A stall while playing the original switches to the fast version, never against the user's own choice. */
    fun fallsBackOnStall(playing: VideoVersion, preference: VideoPreference, hasFast: Boolean, userChose: Boolean): Boolean =
        playing == VideoVersion.Original && preference == VideoPreference.Automatic && hasFast && !userChose
}

/** A fast version is stored with all of its parts (iOS `hasStreamingCopy`); one still uploading can't play. */
val app.lelvo.core.index.LibraryItem.hasFastVersion: Boolean
    get() {
        val have = parts["sp"]?.size ?: 0
        return have > 0 && have == (expectedParts["sp"] ?: 1)
    }

/** Words and numbers the player shows, the same as the iPhone's. */
object VideoLabels {
    /**
     * "4K", "1080p", "720p"… of a version, from the original's pixel size; the fast version is at most 1920 pixels on
     * its long side (iOS `resolutionLabel`). Null without a size.
     */
    fun resolution(width: Int, height: Int, version: VideoVersion): String? {
        val long = maxOf(width, height)
        val short = minOf(width, height)
        if (long <= 0 || short <= 0) return null
        val shown = if (version == VideoVersion.Original) short else Math.round(short * minOf(1.0, 1920.0 / long)).toInt()
        return when {
            shown >= 2160 -> "4K"
            shown >= 1440 -> "1440p"
            shown >= 1080 -> "1080p"
            shown >= 720 -> "720p"
            else -> "${shown}p"
        }
    }

    /** "0:05", "12:34", "1:02:03". */
    fun time(seconds: Double): String {
        if (!seconds.isFinite() || seconds < 0) return "0:00"
        val s = seconds.toLong()
        return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s / 60 % 60, s % 60) else "%d:%02d".format(s / 60, s % 60)
    }

    val speeds = listOf(0.5f, 1f, 1.25f, 1.5f, 2f)

    /** "Normal", "2×", "1.25×". */
    fun speed(s: Float): String = when {
        s == 1f -> "Normal"
        s % 1f == 0f -> "${s.toInt()}×"
        else -> "${s.toString().trimEnd('0')}×"
    }
}

/** When to store a video's fast version, role `sp` (iOS `StreamingCopyPolicy`, the same numbers). */
object StreamingCopyPolicy {
    /** 2 Mbit/s stays below even the low end of measured Telegram speeds (300–900 KB/s), so playback doesn't stop. */
    const val TARGET_BITS_PER_SECOND = 2_000_000

    /** 60 fps videos keep their fluid motion with half as much again. */
    fun targetBitsPerSecond(fps: Float): Int = if (fps > 31) 3_000_000 else TARGET_BITS_PER_SECOND

    /** Below this the original streams about as easily as a fast version would. */
    const val MINIMUM_BITS_PER_SECOND = 4_000_000.0
    const val MINIMUM_BYTES = 4L shl 20
    const val MAXIMUM_SIZE_RATIO = 0.7

    fun bitsPerSecond(item: app.lelvo.core.index.LibraryItem): Double? {
        val d = item.duration ?: return null
        if (d <= 0 || item.fileSize <= 0) return null
        return item.fileSize * 8.0 / d
    }

    fun hasCopy(item: app.lelvo.core.index.LibraryItem): Boolean {
        val have = item.parts["sp"]?.size ?: 0
        return have > 0 && have == (item.expectedParts["sp"] ?: 1)
    }

    fun shouldMake(item: app.lelvo.core.index.LibraryItem): Boolean {
        if (item.kind != app.lelvo.core.index.ItemKind.Video || item.fileSize < MINIMUM_BYTES || item.streamingCopySkipped || hasCopy(item)) return false
        val bits = bitsPerSecond(item) ?: return false
        val long = maxOf(item.width, item.height); val short = minOf(item.width, item.height)
        return bits > MINIMUM_BITS_PER_SECOND || long > 1920 || short > 1080
    }

    fun isWorthKeeping(copyBytes: Long, originalBytes: Long): Boolean = copyBytes > 0 && copyBytes < originalBytes * MAXIMUM_SIZE_RATIO
}
