package app.lelvo.data

import android.util.Log
import app.lelvo.core.format.CaptionCodec
import app.lelvo.core.format.CloudMessage
import app.lelvo.core.format.IndexSnapshot
import app.lelvo.core.format.MetaLog
import app.lelvo.core.format.TrashLog
import app.lelvo.core.index.ItemStatus
import app.lelvo.core.index.LibraryIndexer
import app.lelvo.data.index.LibraryStore
import app.lelvo.telegram.TdFiles
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.drinkless.tdlib.TdApi
import kotlin.coroutines.cancellation.CancellationException

/**
 * Reads the whole library channel into the index (docs/CLOUD_FORMAT.md §7; iOS `LibraryService.scanChannel`, full scan).
 * Read-only on Telegram. Snapshots, notes and following new messages come with Phase C; this is the full scan, which
 * is always correct on its own.
 */
class LibraryScanner(private val files: TdFiles, private val library: LibraryService, private val store: LibraryStore) {
    data class Summary(
        val messages: Int = 0,
        val items: Int = 0,
        val incomplete: Int = 0,
        val orphans: Int = 0,
        val unreadable: Int = 0,
        val trashNotes: Int = 0,
        val metaNotes: Int = 0,
        val snapshots: Int = 0,
    ) {
        override fun toString() =
            "$messages messages: $items items ($incomplete incomplete), $orphans duplicates; notes: $trashNotes Recently Deleted, " +
                "$metaNotes favorites and albums; $snapshots index snapshots"
    }

    suspend fun fullScan(progress: (Int) -> Unit = {}): Summary = withContext(Dispatchers.IO) {
        val chatId = library.chatId ?: throw LibraryException.notALibrary
        val keys = library.keys ?: throw LibraryException.wrongPassphrase
        files.ensureChat(chatId)
        var s = Summary()
        val cloud = ArrayList<CloudMessage>()
        var from = 0L
        while (true) {
            val page = files.documents(chatId, from)
            for (message in page.messages) {
                s = s.copy(messages = s.messages + 1)
                val doc = message.content as? TdApi.MessageDocument ?: continue
                val caption = doc.caption.text
                when {
                    IndexSnapshot.isSnapshot(caption) -> s = s.copy(snapshots = s.snapshots + 1)
                    TrashLog.isNote(caption) -> s = s.copy(trashNotes = s.trashNotes + 1)
                    MetaLog.isNote(caption) -> s = s.copy(metaNotes = s.metaNotes + 1)
                    CaptionCodec.isLelvo(caption) -> try {
                        val meta = CaptionCodec.decode(caption, keys.captionKey)
                        val file = doc.document.document
                        cloud += CloudMessage(message.id, meta, file.remote.id, file.remote.uniqueId, file.size)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (_: Exception) {
                        s = s.copy(unreadable = s.unreadable + 1)
                    }
                }
            }
            progress(s.messages)
            if (page.nextFromMessageId == 0L || page.messages.isEmpty()) break
            from = page.nextFromMessageId
        }
        val result = LibraryIndexer.build(cloud)
        store.replaceAll(result.items)
        s = s.copy(
            items = result.items.size, incomplete = result.items.count { it.status != ItemStatus.BackedUp },
            orphans = result.orphanMessageIds.size,
        )
        Log.i(TAG, "Library scan (full): ${s.messages} messages, ${s.items} items, ${s.incomplete} incomplete, ${s.orphans} duplicates, ${s.unreadable} unreadable")
        s
    }

    private companion object { const val TAG = "Lelvo.Scan" }
}
