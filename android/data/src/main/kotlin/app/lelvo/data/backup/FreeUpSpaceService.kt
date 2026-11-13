package app.lelvo.data.backup

import app.lelvo.core.backup.FreeUpSpace
import app.lelvo.core.index.ItemStatus
import app.lelvo.core.index.LibraryItem
import app.lelvo.core.support.AppLog
import app.lelvo.data.LibraryScanner
import app.lelvo.data.LibraryService
import app.lelvo.data.index.LibraryStore
import app.lelvo.telegram.TdUploads
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Finds backed-up photos that are provably safe to remove from the phone (iOS `FreeUpSpaceService`). The removal
 * itself is the system's trash prompt, run by the screen; nothing here deletes a photo.
 */
class FreeUpSpaceService(
    private val store: LibraryStore,
    private val library: LibraryService,
    private val scanner: LibraryScanner,
    private val uploads: TdUploads,
    private val phone: PhoneFiles,
) {
    /** Backed-up items still on the phone and unchanged since their backup. */
    suspend fun candidates(): List<LibraryItem> = withContext(Dispatchers.IO) {
        val items = store.items(ItemStatus.BackedUp).filter(FreeUpSpace::isCandidate)
        val files = phone.files(items.mapNotNull { it.localId })
        items.filter { item -> files[item.localId]?.let { !FreeUpSpace.mayHaveChanged(item, it.size, it.modifiedAt) } ?: false }
    }

    /** Checks in Telegram that every required part is still there with its recorded size; stamps `verifiedAt` if so. */
    suspend fun verify(item: LibraryItem): Boolean = withContext(Dispatchers.IO) {
        val chatId = library.chatId ?: return@withContext false
        if (!FreeUpSpace.isCandidate(item)) return@withContext false
        try {
            for (role in item.requiredRoles) {
                for (part in item.parts[role].orEmpty()) {
                    val size = uploads.documentSize(chatId, part.messageId)
                    if (size == null) { AppLog.warn("Verification: a part of an item is gone from the channel"); return@withContext false }
                    if (size != part.size) { AppLog.warn("Verification: size mismatch for an item"); return@withContext false }
                }
            }
            store.update(item.id) { it.copy(verifiedAt = System.currentTimeMillis()) }
            true
        } catch (e: Exception) {
            if (e is kotlinx.coroutines.CancellationException) throw e
            AppLog.warn("Verification failed: ${e::class.simpleName}")
            false
        }
    }

    /**
     * What may go now: the library is read again first (it may have been deleted from the backup on another device),
     * each item's current state decides, not the state when it was listed, and each is checked in Telegram once more. Throws when Telegram can't be reached.
     */
    suspend fun safeToRemove(items: List<LibraryItem>): List<LibraryItem> = withContext(Dispatchers.IO) {
        try { scanner.catchUp() } catch (e: Exception) {
            if (e is kotlinx.coroutines.CancellationException) throw e
            throw IllegalStateException("Lelvo needs a connection to Telegram to check your library first. Try again when you're online.")
        }
        val now = System.currentTimeMillis()
        val current = store.items(items.map { it.id })
        val files = phone.files(current.mapNotNull { it.localId })
        current.filter { item ->
            FreeUpSpace.isCandidate(item) && FreeUpSpace.isFreshlyVerified(item, now) &&
                files[item.localId]?.let { !FreeUpSpace.mayHaveChanged(item, it.size, it.modifiedAt) } == true &&
                // Checked in Telegram again right now: a check from earlier today isn't enough to delete on.
                verify(item)
        }
    }

    /** The phone files of [items], for the system's trash prompt. */
    fun files(items: List<LibraryItem>): List<PhoneFile> = phone.files(items.mapNotNull { it.localId }).values.toList()

    /** Which of these phone ids are really gone after the prompt. */
    fun stillOnPhone(localIds: List<String>): Set<String> = phone.files(localIds).keys
}
