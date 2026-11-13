package app.lelvo.data.backup

import app.lelvo.core.backup.CloudDuplicateGroup
import app.lelvo.core.index.ItemStatus
import app.lelvo.core.index.LibraryItem
import app.lelvo.core.support.AppLog
import app.lelvo.data.LibraryException
import app.lelvo.data.LibraryScanner
import app.lelvo.data.LibraryService
import app.lelvo.data.index.LibraryStore
import app.lelvo.telegram.TdUploads
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Extra copies in the Telegram library and identical photos on this phone (iOS `BackupEngine` duplicates and
 * `LibraryService.removeDuplicateMessages`). Nothing goes without a tap; the first copy always stays.
 */
class Duplicates(
    private val store: LibraryStore,
    private val library: LibraryService,
    private val scanner: LibraryScanner,
    private val uploads: TdUploads,
    private val phone: PhoneFiles,
) {
    /** The backed-up item and the identical copies of it on this phone (found by content while backing up). */
    data class PhoneGroup(val item: LibraryItem, val original: PhoneFile?, val copies: List<PhoneFile>)

    suspend fun messageDuplicates(): List<Long> = scanner.duplicateMessageIds()

    suspend fun cloudGroups(): List<CloudDuplicateGroup> = withContext(Dispatchers.IO) {
        val items = store.items(ItemStatus.BackedUp)
        CloudDuplicateGroup.find(items, phone.files(items.mapNotNull { it.localId }).keys)
    }

    suspend fun phoneGroups(): List<PhoneGroup> = withContext(Dispatchers.IO) {
        val aliases = store.aliases()
        val present = phone.files(aliases.keys)
        val byItem = aliases.filterKeys { it in present }.entries.groupBy({ it.value }, { present.getValue(it.key) })
        val items = store.items(byItem.keys).associateBy { it.id }
        val originals = phone.files(items.values.mapNotNull { it.localId })
        byItem.mapNotNull { (itemId, copies) ->
            val item = items[itemId] ?: return@mapNotNull null
            PhoneGroup(item, item.localId?.let(originals::get), copies)
        }.sortedByDescending { it.item.createdAt ?: Long.MIN_VALUE }
    }

    /** Deletes the extra copies a full scan found. */
    suspend fun removeMessageDuplicates() = withContext(Dispatchers.IO) {
        val chatId = library.chatId ?: throw LibraryException.notALibrary
        uploads.deleteMessages(chatId, messageDuplicates())
        scanner.forgetDuplicateMessages()
        AppLog.info("Removed duplicate messages from the library channel")
    }

    /** Deletes the extra items' messages; their photos stay linked to the kept item. */
    suspend fun removeCloudDuplicates(groups: List<CloudDuplicateGroup>): Int = withContext(Dispatchers.IO) {
        val chatId = library.chatId ?: throw LibraryException.notALibrary
        var removed = 0
        for (g in groups) for (extra in g.extras) {
            uploads.deleteMessages(chatId, extra.allMessageIds)
            extra.localId?.let { local ->
                if (g.keep.localId == null) store.update(g.keep.id) { it.copy(localId = local) } else store.addAlias(local, g.keep.id)
            }
            store.delete(extra.id)
            removed++
        }
        AppLog.info("Removed $removed duplicate items from the library")
        removed
    }

    /** After the system's trash prompt: forgets the copies that are really gone. */
    suspend fun forgetDeletedCopies(localIds: List<String>): Int = withContext(Dispatchers.IO) {
        val still = phone.files(localIds).keys
        val gone = localIds.filter { it !in still }
        gone.forEach { store.removeAlias(it) }
        gone.size
    }
}
