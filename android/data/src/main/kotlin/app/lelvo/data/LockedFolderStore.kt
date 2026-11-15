package app.lelvo.data

import android.content.Context
import android.content.SharedPreferences
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Device-local Locked folder ids (timeline entry ids). Same idea as iOS `LockedFolderStore`: never deletes photos,
 * only hides them from the main timeline until biometrics unlock the folder. Not synced via Telegram yet.
 */
class LockedFolderStore(context: Context) {
    private val p: SharedPreferences =
        context.applicationContext.getSharedPreferences("locked_folder", Context.MODE_PRIVATE)

    private val _ids = MutableStateFlow(load(null))
    val ids: StateFlow<Set<String>> = _ids.asStateFlow()

    private val _unlocked = MutableStateFlow(false)
    val unlockedThisSession: StateFlow<Boolean> = _unlocked.asStateFlow()

    private var chatKey: String = "none"

    fun reloadForLibrary(chatId: Long?) {
        chatKey = chatId?.toString() ?: "none"
        _ids.value = load(chatKey)
        _unlocked.value = false
    }

    fun contains(id: String) = id in _ids.value
    fun count() = _ids.value.size

    fun lock(entryIds: Collection<String>) {
        val next = _ids.value + entryIds
        if (next == _ids.value) return
        _ids.value = next
        persist()
    }

    fun unlockItems(entryIds: Collection<String>) {
        val next = _ids.value - entryIds.toSet()
        if (next == _ids.value) return
        _ids.value = next
        persist()
    }

    fun markSessionUnlocked() { _unlocked.value = true }
    fun lockSession() { _unlocked.value = false }

    private fun persist() {
        p.edit().putStringSet(key(chatKey), _ids.value).apply()
    }

    private fun load(chat: String?): Set<String> {
        val k = key(chat ?: chatKey)
        return p.getStringSet(k, null)?.toSet() ?: emptySet()
    }

    private fun key(chat: String) = "ids.$chat"
}
