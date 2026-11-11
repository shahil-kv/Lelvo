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
     * sends about 1 MB/s; phone videos need 2–8), and the viewer can switch to the original.
     */
    fun initial(preference: VideoPreference, hasFast: Boolean): VideoVersion =
        if (hasFast && preference != VideoPreference.Original) VideoVersion.Fast else VideoVersion.Original

    /** A stall while playing the original switches to the fast version, never against the user's own choice. */
    fun fallsBackOnStall(playing: VideoVersion, preference: VideoPreference, hasFast: Boolean, userChose: Boolean): Boolean =
        playing == VideoVersion.Original && preference == VideoPreference.Automatic && hasFast && !userChose
}
