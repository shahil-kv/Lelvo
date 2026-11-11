package app.lelvo.data

import android.content.Context
import android.util.Log
import app.lelvo.core.demo.DemoLibrary
import app.lelvo.core.index.LibraryItem
import app.lelvo.data.index.LibraryStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withContext
import java.io.IOException
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/**
 * Review demo, ported from Shared/App/DemoMode.swift. A reserved phone number and code open the sample library bundled
 * with the app (the iPhone's `iOS/DemoLibrary`, packaged as assets), so a reviewer can try every feature without a
 * Telegram account. In demo mode nothing talks to Telegram: "Back up now" simulates uploading the demo's newest items.
 */
class DemoMode(context: Context, private val store: LibraryStore) {
    private val app = context.applicationContext
    private val prefs = app.getSharedPreferences("demo", Context.MODE_PRIVATE)
    private val _active = MutableStateFlow(prefs.getBoolean(ACTIVE, false))
    val active: StateFlow<Boolean> = _active

    data class Backup(val running: Boolean, val done: Int, val total: Int, val current: List<String>)
    private val _backup = MutableStateFlow<Backup?>(null)
    val backup: StateFlow<Backup?> = _backup

    /** Only when the sample files are in the app, like the iPhone's `folder != nil`. */
    fun matches(phone: String): Boolean = phone.filter { it.isDigit() } == PHONE.filter { it.isDigit() } && manifest() != null

    /** Replaces the local index with the demo library. The newest items wait for "Back up now". */
    suspend fun enter() = withContext(Dispatchers.IO) {
        prefs.edit().putBoolean(ACTIVE, true).putBoolean(PENDING, true).remove(UPLOADED).commit()
        store.deleteAll()
        store.upsert(entries().filter { !it.pending }.map(::item))
        _active.value = true
        Log.i(TAG, "Demo mode: sample library loaded")
    }

    /** Items "on the phone" that the simulated backup uploads; empty once it has run. */
    suspend fun pendingItems(): List<LibraryItem> = withContext(Dispatchers.IO) {
        if (!prefs.getBoolean(PENDING, false)) return@withContext emptyList()
        val uploaded = prefs.getStringSet(UPLOADED, emptySet()) ?: emptySet()
        entries().filter { it.pending }.map(::item).filter { it.id !in uploaded }
    }

    /** "Uploads" the waiting items with real progress and no network. Two at a time, like the real queue. */
    suspend fun runBackup() {
        if (_backup.value?.running == true) return
        val items = pendingItems()
        _backup.value = Backup(true, 0, items.size, emptyList())
        try {
            items.chunked(MAX_UPLOADS).forEach { pair ->
                _backup.value = _backup.value?.copy(current = pair.map { it.filename })
                repeat(10) { delay(120) }
                withContext(Dispatchers.IO) {
                    val now = System.currentTimeMillis()
                    store.upsert(pair.map { it.copy(uploadedAt = now, verifiedAt = now) })
                    // One item finished, so a run that's stopped and started again carries on after it.
                    val done = (prefs.getStringSet(UPLOADED, emptySet()) ?: emptySet()) + pair.map { it.id }
                    prefs.edit().putStringSet(UPLOADED, done).commit()
                }
                _backup.value = _backup.value?.let { it.copy(done = it.done + pair.size) }
            }
            prefs.edit().putBoolean(PENDING, false).remove(UPLOADED).commit()
            Log.i(TAG, "Demo backup finished: ${items.size} items")
        } finally {
            _backup.value = _backup.value?.copy(running = false, current = emptyList())
        }
    }

    /** Sign out: back to a normal, empty app. */
    suspend fun exit() = withContext(Dispatchers.IO) {
        prefs.edit().clear().commit()
        store.deleteAll()
        _backup.value = null
        _active.value = false
    }

    private fun manifest(): String? = try {
        app.assets.open("manifest.json").use { String(it.readBytes(), Charsets.UTF_8) }
    } catch (_: IOException) {
        null
    }

    private fun entries() = manifest()?.let(DemoLibrary::entries) ?: emptyList()

    private fun item(e: DemoLibrary.Entry): LibraryItem =
        DemoLibrary.item(e, LocalDate.now(), ZoneId.systemDefault(), Instant.now())

    companion object {
        /** 555-01xx numbers are reserved for fiction in the North American plan, so this can never be a real account. */
        const val PHONE = "+15550100199"
        const val CODE = "24680"
        private const val MAX_UPLOADS = 2
        private const val ACTIVE = "active"
        private const val PENDING = "pending"
        private const val UPLOADED = "uploaded"
        private const val TAG = "Lelvo.Demo"

        /** Where Coil and the player read a demo item's file; null for every real item. */
        fun assetUri(item: LibraryItem): String? = DemoLibrary.assetName(item)?.let { "file:///android_asset/$it" }
    }
}
