package app.lelvo.data.media

import android.content.Context
import app.lelvo.core.video.VideoNavigation

/**
 * Where each long video was left, on this phone only (iOS `PlaybackPositions`): `VideoNavigation` decides which
 * positions count, and only the most recent 300 are kept. Keyed by item id.
 */
class PlaybackPositions(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences("playback", Context.MODE_PRIVATE)

    fun position(id: String): Double? = prefs.getString(id, null)?.substringBefore('|')?.toDoubleOrNull()

    /** Remembers [seconds], or forgets the video when it was watched to the end or barely started. */
    @Synchronized
    fun record(id: String, seconds: Double, duration: Double) {
        if (!VideoNavigation.shouldRemember(seconds, duration)) {
            if (prefs.contains(id)) prefs.edit().remove(id).apply()
            return
        }
        val edit = prefs.edit().putString(id, "$seconds|${System.currentTimeMillis()}")
        val all = prefs.all
        if (all.size >= LIMIT) {
            all.entries.sortedBy { (it.value as? String)?.substringAfter('|')?.toLongOrNull() ?: 0L }
                .take(all.size - LIMIT + 1).forEach { if (it.key != id) edit.remove(it.key) }
        }
        edit.apply()
    }

    fun clear() = prefs.edit().clear().apply()

    private companion object { const val LIMIT = 300 }
}
