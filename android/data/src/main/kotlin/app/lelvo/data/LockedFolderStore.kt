package app.lelvo.data

import android.content.Context
import android.content.SharedPreferences
import app.lelvo.core.format.MetaLog
import app.lelvo.core.index.GalleryEntry
import app.lelvo.core.index.ItemStatus
import app.lelvo.core.index.LibraryItem
import app.lelvo.data.index.LibraryStore
import app.lelvo.data.LibraryScanner
import app.lelvo.data.sync.NoteSync
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/**
 * Locked Folder session + phone-only pending. Synced membership is [LibraryItem.locked] via MetaLog (#129).
 * Media messages in Telegram are never moved or deleted.
 */
class LockedFolderStore(context: Context) {
    private val p: SharedPreferences =
        context.applicationContext.getSharedPreferences("locked_folder", Context.MODE_PRIVATE)

    private val _pending = MutableStateFlow(emptySet<String>())
    val pendingLocalIds: StateFlow<Set<String>> = _pending.asStateFlow()

    private val _synced = MutableStateFlow(emptySet<String>())
    val syncedLockedIds: StateFlow<Set<String>> = _synced.asStateFlow()

    private val _unlocked = MutableStateFlow(false)
    val unlockedThisSession: StateFlow<Boolean> = _unlocked.asStateFlow()

    private val _setUp = MutableStateFlow(false)
    val isSetUp: StateFlow<Boolean> = _setUp.asStateFlow()

    private var chatKey: String = "none"
    private var backgroundedAtMs: Long? = null

    /** Legacy API used by older UI; prefer [syncedLockedIds] + [pendingLocalIds]. */
    val ids: StateFlow<Set<String>> get() = syncedLockedIds

    fun reloadForLibrary(chatId: Long?) {
        chatKey = chatId?.toString() ?: "none"
        _pending.value = p.getStringSet(pendingKey(chatKey), null)?.toSet() ?: emptySet()
        _setUp.value = p.getBoolean(setupKey(chatKey), false) || _pending.value.isNotEmpty()
        _unlocked.value = false
        backgroundedAtMs = null
    }

    fun count() = _synced.value.size + _pending.value.size

    fun hidesFromTimeline(entry: GalleryEntry): Boolean {
        val item = entry.item
        if (item?.locked == true) return true
        if (item != null && item.id in _synced.value) return true
        val local = entry.asset?.localId
        if (local != null && local in _pending.value) return true
        if (entry.id in _pending.value) return true
        return false
    }

    suspend fun refreshSynced(store: LibraryStore) {
        val locked = store.allItems().filter { it.locked }.map { it.id }.toSet()
        _synced.value = locked
        if (locked.isNotEmpty() || _pending.value.isNotEmpty()) markSetUp()
    }

    /**
     * Pull Locked membership from Telegram (iOS `LockedFolderStore.syncFromChannel`).
     * Same as Recently Deleted / favorites: catch-up for new messages only (weekly full when due); notes are
     * selected by caption prefix — not a forced full library rebuild when Locked is empty.
     */
    suspend fun syncFromChannel(scanner: LibraryScanner, sync: NoteSync, store: LibraryStore) {
        val localLocked = store.allItems().filter {
            it.locked && (it.status == ItemStatus.BackedUp || it.status == ItemStatus.Trashed)
        }
        if (localLocked.isNotEmpty()) {
            runCatching { sync.change(localLocked, MetaLog.Key.Locked, true) }
        }
        runCatching { scanner.catchUp() }
            .onFailure { runCatching { scanner.applyMetaNotesNow(null) } }
        runCatching { scanner.applyMetaNotesNow(null) }
        refreshSynced(store)
    }

    suspend fun lockEntries(
        entries: List<GalleryEntry>,
        store: LibraryStore,
        sync: NoteSync,
        enqueueBackup: (List<String>) -> Unit,
    ): Int {
        val cloud = ArrayList<LibraryItem>()
        val pending = ArrayList<String>()
        val toBackUp = ArrayList<String>()
        for (entry in entries) {
            val item = entry.item
            val asset = entry.asset
            when {
                item != null && (item.status == ItemStatus.BackedUp || item.status == ItemStatus.Trashed) -> cloud += item
                asset != null -> {
                    pending += asset.localId
                    if (item == null || item.status != ItemStatus.BackedUp) toBackUp += asset.localId
                }
                item?.localId != null -> pending += item.localId!!
            }
        }
        var changed = 0
        if (cloud.isNotEmpty()) {
            changed += sync.change(cloud, MetaLog.Key.Locked, true)
            refreshSynced(store)
        }
        if (pending.isNotEmpty()) {
            val next = _pending.value + pending
            if (next != _pending.value) {
                _pending.value = next
                persistPending()
                changed += pending.size
            }
        }
        if (toBackUp.isNotEmpty()) enqueueBackup(toBackUp)
        if (!_setUp.value) markSetUp()
        return changed
    }

    suspend fun unlockEntries(entries: List<GalleryEntry>, store: LibraryStore, sync: NoteSync): Int {
        val cloud = ArrayList<LibraryItem>()
        val pending = ArrayList<String>()
        for (entry in entries) {
            entry.item?.let {
                cloud += it
                it.localId?.let(pending::add)
            }
            entry.asset?.localId?.let(pending::add)
            pending += entry.id
        }
        var changed = 0
        if (cloud.isNotEmpty()) {
            changed += sync.change(cloud, MetaLog.Key.Locked, false)
            refreshSynced(store)
        }
        val next = _pending.value - pending.toSet()
        if (next != _pending.value) {
            _pending.value = next
            persistPending()
            changed += 1
        }
        return changed
    }

    suspend fun promotePendingAfterBackup(item: LibraryItem, sync: NoteSync, store: LibraryStore) {
        val local = item.localId ?: return
        if (local !in _pending.value) return
        if (item.status != ItemStatus.BackedUp && item.status != ItemStatus.Trashed) return
        sync.change(listOf(item), MetaLog.Key.Locked, true)
        _pending.update { it - local }
        persistPending()
        refreshSynced(store)
    }

    fun markSessionUnlocked() { _unlocked.value = true }
    fun lockSession() { _unlocked.value = false }

    fun markSetUp() {
        if (_setUp.value) return
        _setUp.value = true
        p.edit().putBoolean(setupKey(chatKey), true).apply()
    }

    fun noteEnteredBackground() {
        backgroundedAtMs = System.currentTimeMillis()
        if (autoLockMs() == 0) lockSession()
    }

    fun noteBecameActive() {
        val at = backgroundedAtMs
        backgroundedAtMs = null
        if (!_unlocked.value || at == null) return
        if (System.currentTimeMillis() - at >= autoLockMs()) lockSession()
    }

    fun autoLockMs(): Int = p.getInt(AUTO_LOCK_MS, DEFAULT_AUTO_LOCK_MS).coerceAtLeast(0)

    fun setAutoLockMs(ms: Int) {
        p.edit().putInt(AUTO_LOCK_MS, ms.coerceAtLeast(0)).apply()
    }

    private fun persistPending() {
        p.edit().putStringSet(pendingKey(chatKey), _pending.value).apply()
    }

    private fun pendingKey(chat: String) = "pending.$chat"
    private fun setupKey(chat: String) = "setup.$chat"

    companion object {
        const val AUTO_LOCK_MS = "auto_lock_ms"
        const val DEFAULT_AUTO_LOCK_MS = 5_000
        val AUTO_LOCK_OPTIONS_MS = listOf(0, 5_000, 15_000, 60_000, 300_000, 1_800_000)
    }
}
