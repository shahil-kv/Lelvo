package app.lelvo.data

import app.lelvo.core.crypto.FileCrypto
import app.lelvo.core.format.CaptionCodec
import app.lelvo.core.format.CloudMessage
import app.lelvo.core.format.IndexSnapshot
import app.lelvo.core.format.MetaLog
import app.lelvo.core.format.TrashLog
import app.lelvo.core.index.ItemStatus
import app.lelvo.core.index.LibraryIndexer
import app.lelvo.core.index.LibraryItem
import app.lelvo.core.support.AppLog
import app.lelvo.data.index.LibraryStore
import app.lelvo.telegram.TdClient
import app.lelvo.telegram.TdFiles
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.drinkless.tdlib.TdApi
import kotlin.coroutines.cancellation.CancellationException

/**
 * Reads the library channel into the index (docs/CLOUD_FORMAT.md §7; iOS `LibraryService.scanChannel`): a full scan
 * of every message, or a recent one of the messages since the last scan; Recently Deleted and favorites and albums
 * notes; the index snapshot on a phone with an empty index; and live changes from the user's other devices while the
 * app runs. Read-only on Telegram.
 */
class LibraryScanner(
    private val files: TdFiles,
    private val library: LibraryService,
    private val store: LibraryStore,
    private val td: TdClient,
) {
    data class Summary(
        val messages: Int = 0,
        val items: Int = 0,
        val incomplete: Int = 0,
        val orphans: Int = 0,
        val unreadable: Int = 0,
        val trashNotes: Int = 0,
        val metaNotes: Int = 0,
        val snapshots: Int = 0,
        val fromSnapshot: Boolean = false,
    ) {
        override fun toString() =
            "$messages messages: $items items ($incomplete incomplete), $orphans duplicates; notes: $trashNotes Recently Deleted, " +
                "$metaNotes favorites and albums; $snapshots index snapshots"
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    // One scan at a time, and live deletes in between, never during: two at once wrote into the index together on iOS.
    private val gate = Mutex()
    @Volatile private var lastFull: Triple<Long, Long, Summary>? = null

    /** Reads every message of the channel and rebuilds the index from it. */
    suspend fun fullScan(progress: (Int) -> Unit = {}): Summary = scan(full = true, progress)

    /**
     * `full == false` only reads messages newer than the last scan. A full scan of this library that finished while
     * this one waited has already done the work.
     */
    suspend fun scan(full: Boolean, progress: (Int) -> Unit = {}): Summary = withContext(Dispatchers.IO) {
        val asked = System.currentTimeMillis()
        gate.withLock {
            lastFull?.let { (chat, finished, summary) -> if (chat == library.chatId && finished > asked) return@withLock summary }
            scanChannel(full, progress)
        }
    }

    /**
     * Brings the index up to date after launch or sign-in: a full scan once a week, since a note can be finished and
     * gone before this phone saw it (iOS `catchUp`), otherwise the messages since the last scan.
     */
    suspend fun catchUp(): Summary {
        val chatId = library.chatId ?: throw LibraryException.notALibrary
        files.ensureChat(chatId)
        // Opening the chat makes TDLib ask Telegram what changed while it wasn't listening, and sends live updates.
        runCatching { td.send(TdApi.OpenChat(chatId)) }
        val lastFullAt = store.meta(LAST_FULL_SCAN_AT)?.toLongOrNull()
        return scan(full = TrashLog.needsFullScan(lastFullAt, System.currentTimeMillis()))
    }

    private class FoundNote(val messageId: Long, val date: Long, val caption: String, val remoteId: String)

    private suspend fun scanChannel(requestedFull: Boolean, progress: (Int) -> Unit): Summary {
        val chatId = library.chatId ?: throw LibraryException.notALibrary
        val keys = library.keys ?: throw LibraryException.wrongPassphrase
        // The index is a cache of one library. Another library chosen since (on this screen or after a reset that
        // didn't finish) starts from empty, so none of its items are taken for vanished ones of this library.
        if (store.meta(LIBRARY) != chatId.toString()) {
            store.deleteAll()
            store.setMeta(LIBRARY, chatId.toString())
        }
        // The first scan of this index is always full, so every item is built from its own captions.
        val full = requestedFull || store.meta(REPAIRED) == null
        files.ensureChat(chatId)
        val stopAt = if (full) 0L else store.meta(LAST_SCAN)?.toLongOrNull() ?: 0L
        // A phone with an empty index (new phone, reinstall) can take everything older than the newest snapshot from it.
        val allowSnapshot = full && store.allItems().none { it.hasCloudParts }
        var fromSnapshot: IndexSnapshot.Body? = null
        var s = Summary()
        val cloud = ArrayList<CloudMessage>()
        val trash = ArrayList<FoundNote>()
        val meta = ArrayList<FoundNote>()
        var from = 0L
        var newest = 0L
        scan@ while (true) {
            val page = files.documents(chatId, from)
            for (message in page.messages) {
                newest = maxOf(newest, message.id)
                if (message.id <= stopAt) break@scan
                s = s.copy(messages = s.messages + 1)
                val doc = message.content as? TdApi.MessageDocument ?: continue
                val caption = doc.caption.text
                val file = doc.document.document
                when {
                    IndexSnapshot.isSnapshot(caption) -> {
                        s = s.copy(snapshots = s.snapshots + 1)
                        if (allowSnapshot) readSnapshot(caption, file.remote.id, keys.master, keys.captionKey)?.let {
                            fromSnapshot = it
                            break@scan
                        }
                    }
                    TrashLog.isNote(caption) -> trash += FoundNote(message.id, message.date.toLong(), caption, file.remote.id)
                    MetaLog.isNote(caption) -> meta += FoundNote(message.id, message.date.toLong(), caption, file.remote.id)
                    CaptionCodec.isLelvo(caption) -> try {
                        cloud += CloudMessage(message.id, CaptionCodec.decode(caption, keys.captionKey), file.remote.id, file.remote.uniqueId, file.size)
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
        s = s.copy(trashNotes = trash.size, metaNotes = meta.size)

        // Before the scan position moves: a note that couldn't be downloaded is read again by the next scan.
        readTrashNotes(trash, keys.master, keys.captionKey)
        val newMetaIds = readMetaNotes(meta, keys.master, keys.captionKey)

        fromSnapshot?.let { snapshot ->
            // Newer messages read above win over the snapshot's copy of the same message.
            val read = cloud.map { it.messageId }.toHashSet()
            cloud += snapshot.messages.filter { it.messageId !in read }
            s = merge(cloud, full = false, s)
            applyTrashNotes(messagesSeen = false)
            applyMetaNotes(only = null)
            if (newest > 0) store.setMeta(LAST_SCAN, newest.toString())
            AppLog.info("Library restored from the index snapshot up to message ${snapshot.upto}: ${s.items} items, ${s.messages} newer messages read; checking the whole channel next")
            // The channel is the truth: a full scan in the background catches anything deleted since the snapshot.
            scope.launch { runCatching { scan(full = true) } }
            return s.copy(fromSnapshot = true)
        }

        s = merge(cloud, full, s)
        if (full) {
            store.setMeta(LAST_FULL_SCAN_AT, System.currentTimeMillis().toString())
            // Notes no longer in the channel: removed by a device whose 30 days were over, or in the Telegram app. Only
            // up to where this scan read: a note sent during the scan is newer, and dropping it would undo that delete.
            val trashIn = trash.map { it.messageId }.toHashSet()
            store.removeTrashNotes(store.trashNotes().map { it.messageId }.filter { it !in trashIn && it <= newest })
            val metaIn = meta.map { it.messageId }.toHashSet()
            store.removeMetaNotes(store.metaNotes().map { it.messageId }.filter { it !in metaIn && it <= newest })
        }
        applyTrashNotes(messagesSeen = full)
        // After the merge, which takes favorites and albums from the captions: notes go on top. A recent scan only
        // touches the items it read and the items in new notes; a full scan checks every one.
        applyMetaNotes(only = if (full) null else newMetaIds + cloud.map { it.meta.id })
        if (newest > 0) store.setMeta(LAST_SCAN, newest.toString())
        if (full) {
            store.setMeta(REPAIRED, "1")
            lastFull = Triple(chatId, System.currentTimeMillis(), s)
        }
        AppLog.info("Library scan (${if (full) "full" else "recent"}): ${s.messages} messages, ${s.items} items, ${s.incomplete} incomplete, ${s.orphans} duplicates, ${s.unreadable} unreadable")
        return s
    }

    /** Merges scanned items into the index, keeping what only this phone knows (iOS `merge`). */
    private suspend fun merge(cloud: List<CloudMessage>, full: Boolean, summary: Summary): Summary {
        val existing = store.allItems().associateBy { it.id }
        // A recent scan only sees new messages; combine them with the parts already known.
        val messages = if (full) cloud else {
            val ids = cloud.map { it.meta.id }.toHashSet()
            val scanned = cloud.map { it.messageId }.toHashSet()
            cloud + existing.values.filter { it.id in ids }.flatMap { LibraryIndexer.knownMessages(it, scanned) }
        }
        val result = LibraryIndexer.build(messages)
        val merged = ArrayList<LibraryItem>(result.items.size)
        // Favorites and albums notes go on in the same write as the captions: written one after the other, the
        // timeline briefly showed favorites as the captions had them.
        val metaLatest = MetaLog.latest(store.metaNotes())
        for (built in result.items) {
            val local = existing[built.id]
            var item = built
            if (metaLatest.containsKey(item.id)) {
                val applied = MetaLog.apply(MetaLog.values(item.id, metaLatest, null), item.favorite, item.albums)
                if (applied.changed) item = item.copy(favorite = applied.favorite ?: false, albums = applied.albums ?: emptyList())
            }
            if (local != null) {
                item = item.keepingLocalState(local)
                // Incomplete ones too: Recently Deleted can hold an item missing a part.
                if (local.status == ItemStatus.Trashed) item = item.copy(status = ItemStatus.Trashed, trashedAt = local.trashedAt)
                if (item.status != ItemStatus.BackedUp && (local.status == ItemStatus.Uploading || local.status == ItemStatus.Queued) && !item.isStrandedInCloud) {
                    // Still being uploaded by this phone: keep the queue state, update known parts.
                    item = item.copy(status = local.status, lastError = local.lastError)
                }
            }
            merged += item
        }
        if (full) {
            val seen = result.items.map { it.id }.toHashSet()
            for (item in existing.values) {
                if (item.id in seen) continue
                when {
                    // Deleted elsewhere while in Recently Deleted here: nothing left to recover.
                    item.status == ItemStatus.Trashed -> store.forgetDeletedItem(item)
                    // Vanished from the channel: a photo still on this phone uploads again; anything else goes.
                    item.hasCloudParts && item.status == ItemStatus.BackedUp ->
                        if (item.localId != null) merged += item.copy(status = ItemStatus.Failed, parts = emptyMap(), lastError = LibraryIndexer.NOT_FOUND)
                        else store.delete(item.id)
                }
            }
        }
        store.upsert(merged)
        return summary.copy(
            items = result.items.size, incomplete = result.items.count { it.status != ItemStatus.BackedUp },
            orphans = result.orphanMessageIds.size,
        )
    }

    // Recently Deleted across devices (docs/CLOUD_FORMAT.md §7.2)

    /** Downloads notes this phone hasn't read. A network failure throws; a damaged note changes nothing. */
    private suspend fun readTrashNotes(found: List<FoundNote>, master: ByteArray, captionKey: ByteArray) {
        val known = store.trashNotes().map { it.messageId }.toHashSet()
        for (note in found) {
            if (note.messageId in known) continue
            val caption = note.caption.takeIf { it.startsWith(TrashLog.ENCRYPTED_PREFIX) }?.let { TrashLog.parseCaption(it, captionKey) }
            val body = caption?.let { c -> download(note.remoteId, master)?.let { TrashLog.read(it, c) } }
            if (body == null) { AppLog.warn("Skipped a Recently Deleted note that can't be read"); continue }
            store.addTrashNote(TrashLog.Note(note.messageId, note.date, body.op, body.ids))
        }
    }

    /** Makes the index follow the newest note of each item. Notes stay stored, so one that arrived before its photo takes effect later. */
    private suspend fun applyTrashNotes(messagesSeen: Boolean) {
        val notes = store.trashNotes()
        if (notes.isEmpty()) return
        val newest = TrashLog.latest(notes)
        val changed = ArrayList<LibraryItem>()
        var removed = 0
        for (item in store.items(newest.keys)) {
            val note = newest[item.id] ?: continue
            when (val action = TrashLog.action(item, note, messagesSeen)) {
                TrashLog.Action.Remove -> { store.forgetDeletedItem(item); removed++ }
                else -> TrashLog.apply(action, item)?.let { changed += it }
            }
        }
        store.upsert(changed)
        if (changed.isNotEmpty() || removed > 0) AppLog.info("Recently Deleted synced: ${changed.size} items updated, $removed removed")
    }

    // Favorites and albums across devices (docs/CLOUD_FORMAT.md §7.3)

    /** Downloads notes this phone hasn't read; returns the items they're about. */
    private suspend fun readMetaNotes(found: List<FoundNote>, master: ByteArray, captionKey: ByteArray): Set<String> {
        val known = store.metaNotes().map { it.messageId }.toHashSet()
        val touched = HashSet<String>()
        for (note in found) {
            if (note.messageId in known) continue
            val caption = note.caption.takeIf { it.startsWith(MetaLog.ENCRYPTED_PREFIX) }?.let { MetaLog.parseCaption(it, captionKey) }
            val body = caption?.let { c -> download(note.remoteId, master)?.let { MetaLog.read(it, c) } }
            if (body == null) { AppLog.warn("Skipped a favorites and albums note that can't be read"); continue }
            store.addMetaNote(MetaLog.Note(note.messageId, note.date, body.op, body.ids, body.album))
            touched += body.ids
        }
        return touched
    }

    /** Makes each item's favorite and albums follow its newest notes. [only]: just these items. */
    private suspend fun applyMetaNotes(only: Set<String>?) {
        val notes = store.metaNotes()
        if (notes.isEmpty()) return
        val latest = MetaLog.latest(notes)
        val ids = only?.intersect(latest.keys) ?: latest.keys
        if (ids.isEmpty()) return
        val changed = store.items(ids).mapNotNull { item ->
            val applied = MetaLog.apply(MetaLog.values(item.id, latest, null), item.favorite, item.albums)
            if (applied.changed) item.copy(favorite = applied.favorite ?: false, albums = applied.albums ?: emptyList()) else null
        }
        store.upsert(changed)
        if (changed.isNotEmpty()) AppLog.info("Favorites and albums synced: ${changed.size} items updated")
    }

    /** A note's document, decrypted; null when it can't be opened. A network failure throws. */
    private suspend fun download(remoteId: String, master: ByteArray): ByteArray? {
        val file = files.download(remoteId, priority = 32)
        try {
            return runCatching { FileCrypto.decrypt(file.readBytes(), master) }.getOrNull()
        } finally {
            files.deleteLocalCopy(remoteId)
        }
    }

    // Index snapshots (docs/CLOUD_FORMAT.md §7.1)

    /** Downloads and checks a snapshot; null (and a full scan instead) when anything about it is off. */
    private suspend fun readSnapshot(caption: String, remoteId: String, master: ByteArray, captionKey: ByteArray): IndexSnapshot.Body? {
        val info = caption.takeIf { it.startsWith(IndexSnapshot.ENCRYPTED_PREFIX) }?.let { IndexSnapshot.parseCaption(it, captionKey) } ?: return null
        return try {
            download(remoteId, master)?.let { IndexSnapshot.read(it, info) }
                ?: null.also { AppLog.warn("Index snapshot doesn't check out; reading the whole channel instead") }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            AppLog.warn("Couldn't read the index snapshot; reading the whole channel instead", e)
            null
        }
    }

    // Live changes from the other device

    private val pendingDeletes = HashSet<Long>()
    @Volatile private var recentScanScheduled = false
    @Volatile private var deletesScheduled = false

    /**
     * Uploads and deletes made on the user's other device show here while the app is open, instead of at the next
     * scan. Both wait a second to batch: a backup elsewhere sends a message every few seconds, and a bulk delete
     * arrives in many updates. Scans stay the catch-up path for whatever happened while the app wasn't running.
     */
    fun follow() {
        scope.launch {
            td.updates.collect { update ->
                val chatId = library.chatId ?: return@collect
                when (update) {
                    is TdApi.UpdateNewMessage -> if (update.message.chatId == chatId && update.message.sendingState == null && !recentScanScheduled) {
                        recentScanScheduled = true
                        scope.launch {
                            delay(1_000)
                            recentScanScheduled = false
                            if (library.isUnlocked && library.setupFinished) runCatching { scan(full = false) }
                                .onFailure { if (it !is CancellationException) AppLog.warn("Couldn't read new library messages", it) }
                        }
                    }
                    // Only deletes Telegram made for good, not TDLib dropping messages from its cache.
                    is TdApi.UpdateDeleteMessages -> if (update.chatId == chatId && update.isPermanent && !update.fromCache) {
                        val start = synchronized(pendingDeletes) {
                            pendingDeletes.addAll(update.messageIds.toList())
                            !deletesScheduled.also { deletesScheduled = true }
                        }
                        if (start) scope.launch { delay(1_000); applyDeletes() }
                    }
                    else -> Unit
                }
            }
        }
    }

    /** The same rules as a full scan, for the items that owned the deleted messages (iOS `applyDeletes`). */
    private suspend fun applyDeletes() = gate.withLock {
        val ids = synchronized(pendingDeletes) { pendingDeletes.toSet().also { pendingDeletes.clear(); deletesScheduled = false } }
        if (ids.isEmpty() || !library.isUnlocked) return@withLock
        store.removeTrashNotes(ids)
        // Favorites and albums notes go only once newer ones decide everything they did: nothing to follow.
        store.removeMetaNotes(ids)
        val changed = ArrayList<LibraryItem>()
        var removed = 0
        for (item in store.allItems()) {
            when (val outcome = LibraryIndexer.afterDeleting(ids, item)) {
                LibraryIndexer.DeleteOutcome.Unchanged -> Unit
                is LibraryIndexer.DeleteOutcome.Update -> changed += outcome.item
                LibraryIndexer.DeleteOutcome.Remove -> {
                    if (item.status == ItemStatus.Trashed) store.forgetDeletedItem(item) else store.delete(item.id)
                    removed++
                }
            }
        }
        store.upsert(changed)
        if (changed.isNotEmpty() || removed > 0) AppLog.info("Deleted on another device: ${ids.size} messages, $removed items removed, ${changed.size} updated")
    }

    private companion object {
        const val LAST_SCAN = "lastScannedMessageId"
        const val LAST_FULL_SCAN_AT = "lastChannelFullScanAt"
        const val REPAIRED = "fullScanDone"
        const val LIBRARY = "libraryChatId"
    }
}
