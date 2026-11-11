package app.lelvo.data

import android.content.Context
import android.content.SharedPreferences
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow

/**
 * The app's settings, with the iPhone's keys and defaults (Shared/Services/Preferences.swift), so the two apps behave
 * the same out of the box. Left out on purpose: `includeHidden` (Android has no hidden photos), `encryptionEnabled`
 * (Android is end-to-end encrypted only), `chatType`/`chatTitle`/`botUsername` (the old Bot API app),
 * `secondCopyBookmark`/`secondCopyVolume` (a Storage Access Framework folder replaces them in Phase I),
 * `onboardingComplete` (the sign-in state and the library decide that on Android).
 */
class Prefs(context: Context) {
    private val p: SharedPreferences = context.applicationContext.getSharedPreferences("settings", Context.MODE_PRIVATE)

    enum class AlbumMode(val code: String, val title: String) {
        All("all", "All photos"), Include("include", "Only selected albums"), Exclude("exclude", "All except selected albums");
        companion object { fun of(code: String?) = entries.firstOrNull { it.code == code } ?: All }
    }

    enum class MediaFilter(val code: String, val title: String) {
        All("all", "Photos and videos"), Photos("photos", "Photos only"), Videos("videos", "Videos only");
        companion object { fun of(code: String?) = entries.firstOrNull { it.code == code } ?: All }
    }

    /** iOS `VideoQualityPreference`. */
    enum class VideoQuality(val code: String) {
        Automatic("automatic"), Original("original"), Fast("fast");
        companion object { fun of(code: String?) = entries.firstOrNull { it.code == code } ?: Automatic }
    }

    var wifiOnly by flag("wifiOnly", true)
    var backupVideos by flag("backupVideos", true)
    var includeScreenshots by flag("includeScreenshots", true)
    var chargingOnly by flag("chargingOnly", false)
    var allowFreeUpSpace by flag("allowFreeUpSpace", false)
    var autoBackup by flag("autoBackup", false)
    var streamingCopies by flag("streamingCopies", true)
    var keepAwakeDuringBackup by flag("keepAwakeDuringBackup", true)
    var backupPaused by flag("backupPaused", false)

    var albumMode: AlbumMode
        get() = AlbumMode.of(p.getString("albumMode", null))
        set(v) = p.edit().putString("albumMode", v.code).apply()
    var albumIds: Set<String>
        get() = p.getStringSet("albumIds", null)?.toSet() ?: emptySet()
        set(v) = p.edit().putStringSet("albumIds", v).apply()
    var mediaFilter: MediaFilter
        get() = MediaFilter.of(p.getString("mediaFilter", null))
        set(v) = p.edit().putString("mediaFilter", v.code).apply()
    var videoQuality: VideoQuality
        get() = VideoQuality.of(p.getString("videoQuality", null))
        set(v) = p.edit().putString("videoQuality", v.code).apply()

    /** Back up only items taken on or after this day (epoch ms), when set. */
    var dateFrom: Long?
        get() = p.getLong("dateFrom", 0).takeIf { it > 0 }
        set(v) = p.edit().apply { if (v == null) remove("dateFrom") else putLong("dateFrom", v) }.apply()
    var lastBackupAt: Long?
        get() = p.getLong("lastBackupAt", 0).takeIf { it > 0 }
        set(v) = p.edit().apply { if (v == null) remove("lastBackupAt") else putLong("lastBackupAt", v) }.apply()

    /** Same floors as iOS: at least 100 MB of media cache and 50 MB of thumbnails. */
    val mediaCacheBytes: Long get() = maxOf(100, p.getInt("cacheCapMB", 1000)).toLong() shl 20
    val thumbnailCacheBytes: Long get() = maxOf(50, p.getInt("thumbnailCacheMB", 300)).toLong() shl 20

    /** Columns in the Photos grid, kept across launches like iOS `gridColumns`; 3 is the day view. */
    var gridColumns: Int
        get() = p.getInt("gridColumns", 3)
        set(v) = p.edit().putInt("gridColumns", v).apply()

    /** The memory types turned on (iOS `MemoriesSettingsView`, same keys): all by default. */
    val memoryKinds: Set<app.lelvo.core.memories.Memories.KindFilter>
        get() = app.lelvo.core.memories.Memories.KindFilter.entries.filterTo(HashSet()) { p.getBoolean("memories.${it.key}", true) }

    fun setMemoryKind(kind: app.lelvo.core.memories.Memories.KindFilter, on: Boolean) = p.edit().putBoolean("memories.${kind.key}", on).apply()

    /** Sign out: every setting back to its default, like a fresh install. */
    fun reset() = p.edit().clear().apply()

    /** Emits the key of each change, for screens that show a setting. */
    fun changes(): Flow<String> = callbackFlow {
        val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, key -> if (key != null) trySend(key) }
        p.registerOnSharedPreferenceChangeListener(listener)
        awaitClose { p.unregisterOnSharedPreferenceChangeListener(listener) }
    }

    private fun flag(key: String, default: Boolean) = object : kotlin.properties.ReadWriteProperty<Any?, Boolean> {
        override fun getValue(thisRef: Any?, property: kotlin.reflect.KProperty<*>) = p.getBoolean(key, default)
        override fun setValue(thisRef: Any?, property: kotlin.reflect.KProperty<*>, value: Boolean) = p.edit().putBoolean(key, value).apply()
    }
}
