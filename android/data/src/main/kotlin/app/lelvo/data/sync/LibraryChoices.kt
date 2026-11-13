package app.lelvo.data.sync

import app.lelvo.core.support.AppLog
import app.lelvo.core.sync.KeptChoices
import app.lelvo.data.index.LibraryStore
import java.io.File

/**
 * What the user chose in a library that only this phone knows, kept per library outside the index (iOS
 * `LibrarySnapshots.saveChoices` / `restoreChoices`): photos deleted for good that must not be backed up again, and
 * Recently Deleted, favorite and album changes not sent yet. The index holds one library at a time, so without this a
 * switch and back, or signing in again after the session ended elsewhere, would back up deleted photos again and
 * undo unsent changes.
 */
class LibraryChoices(private val dir: File) {
    private fun file(chatId: Long) = File(dir, "choices-$chatId.json")

    suspend fun save(chatId: Long, store: LibraryStore) {
        val choices = KeptChoices(store.noBackupKeys(), store.queuedTrashChanges(chatId), store.queuedMetaChanges(chatId))
        val f = file(chatId)
        if (choices.isEmpty) { f.delete(); return }
        runCatching {
            dir.mkdirs()
            val tmp = File(dir, f.name + ".tmp")
            tmp.writeText(choices.encode())
            if (!tmp.renameTo(f)) { f.delete(); check(tmp.renameTo(f)) }
            AppLog.info("Kept this library's choices: ${choices.offBackup.size} off backup, ${choices.waiting.values.sumOf { it.size }} Recently Deleted and ${choices.meta.size} favorites and albums changes waiting")
        }.onFailure { AppLog.warn("Couldn't keep this library's choices", it) }
    }

    /** Puts them back into the (fresh) index; returns whether changes are waiting to be sent. */
    suspend fun restore(chatId: Long, store: LibraryStore): Boolean {
        val f = file(chatId)
        if (!f.isFile) return false
        val choices = runCatching { KeptChoices.decode(f.readText()) }.getOrNull() ?: return false
        store.restoreNoBackupKeys(choices.offBackup)
        choices.waiting.forEach { (op, ids) -> store.queueTrashChange(op, ids, chatId) }
        if (choices.meta.isNotEmpty()) store.queueMetaChanges(choices.meta, chatId)
        AppLog.info("Restored this library's choices")
        return choices.waiting.isNotEmpty() || choices.meta.isNotEmpty()
    }

    /** Sign out: every library's choices go. */
    fun removeAll() { dir.deleteRecursively() }
}
