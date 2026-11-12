package app.lelvo.data.sync

import android.content.Context
import app.lelvo.core.crypto.FileCrypto
import app.lelvo.core.crypto.Hashing
import app.lelvo.core.format.MetaLog
import app.lelvo.core.format.NoteCaption
import app.lelvo.core.format.PhotosFavorite
import app.lelvo.core.format.TrashLog
import app.lelvo.core.index.CloudTrash
import app.lelvo.core.index.ItemStatus
import app.lelvo.core.index.LibraryItem
import app.lelvo.core.session.TelegramErrors
import app.lelvo.core.support.AppLog
import app.lelvo.data.LibraryException
import app.lelvo.data.LibraryScanner
import app.lelvo.data.LibraryService
import app.lelvo.data.backup.BackupEngine
import app.lelvo.data.index.LibraryStore
import app.lelvo.data.media.PhotoAccess
import app.lelvo.telegram.AuthStep
import app.lelvo.telegram.TdClient
import app.lelvo.telegram.TdFiles
import app.lelvo.telegram.TdUploads
import app.lelvo.telegram.TelegramException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import java.util.UUID

/** What the user reads when Recover can't finish (iOS `TrashError`). */
class TrashException(message: String) : Exception(message) {
    companion object {
        val alreadyDeleting = TrashException("Some items were already being removed from your Telegram library and couldn't be recovered.")
        fun alreadyGone(count: Int) = TrashException(
            if (count == 1) "This photo was already deleted from your Telegram library on another device, so it can't be recovered."
            else "$count photos were already deleted from your Telegram library on another device, so they can't be recovered.",
        )
        val needsConnection = TrashException("Couldn't reach Telegram. Check your connection and try again.")
    }
}

/**
 * Recently Deleted, favorites and albums on every device (docs/CLOUD_FORMAT.md §7.2, §7.3): the Android side of iOS
 * `TrashSync`, `MetaSync`, `PhotosFavoriteSync` and the Recently Deleted half of `GalleryActions`.
 *
 * A change is written to the index and queued in its outbox in one transaction, so it survives the app closing and a
 * scan can't undo it. Notes go grouped (5 s) and at most one every 10 s per kind, through the backup engine's upload
 * slots and FLOOD_WAIT pause. Every write to the channel asks [LibraryService.requireWritable] first.
 */
class NoteSync(
    context: Context,
    private val store: LibraryStore,
    private val library: LibraryService,
    private val scanner: LibraryScanner,
    private val files: TdFiles,
    private val uploads: TdUploads,
    private val engine: BackupEngine,
    private val telegram: TdClient,
    private val photos: PhotoAccess,
    private val isDemo: () -> Boolean,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    // Per library and not in the index, which a library switch clears (iOS keeps it in UserDefaults for the same reason).
    private val prefs = context.getSharedPreferences("sync", Context.MODE_PRIVATE)
    private val staging = File(context.cacheDir, "notes")

    private val trashPacer = Pacer("Recently Deleted") { sendTrash() }
    private val metaPacer = Pacer("favorites and albums") { sendMeta() }
    private val trashSend = Mutex()
    private val metaSend = Mutex()
    private val trashCleaning = Mutex()
    private val metaCleaning = Mutex()
    private val opening = Mutex()
    @Volatile private var lastOpenCheck = 0L
    private val gate = TrashGate()

    init {
        scanner.onTrashNoteRemoved = { followOtherDevice() }
    }

    /** The library notes are queued for; null in the demo, where changes stay on this phone. */
    val noteChatId: Long? get() = if (isDemo()) null else library.chatId

    private val ready: Boolean get() = !isDemo() && library.isConfigured && library.isUnlocked

    /** The library, when this build may write to it (only "Android test" before the gate); null otherwise. */
    private suspend fun writableChat(): Long? {
        val chatId = library.chatId ?: return null
        return try { library.requireWritable(chatId); chatId } catch (e: LibraryException) { null }
    }

    // MARK: Actions the user takes

    /**
     * Sets the favorite or an album on items in the Telegram library and queues the note (iOS `MetaSync.change`).
     * Items without a finished backup aren't touched: their favorite and albums go with their backup.
     */
    suspend fun change(items: List<LibraryItem>, key: MetaLog.Key, value: Boolean): Int {
        val ids = items.filter { it.status == ItemStatus.BackedUp || it.status == ItemStatus.Trashed }.map { it.id }
        if (ids.isEmpty()) return 0
        val chatId = noteChatId
        chatId?.let { library.requireWritable(it) }
        store.changeMeta(ids, key, value, chatId)
        if (chatId != null) metaPacer.schedule()
        return ids.size
    }

    /**
     * Moves the items to Recently Deleted (iOS `deleteFromCloud`): hidden everywhere and no longer counted as backed
     * up, but their messages stay for 30 days, so a mistaken delete can be undone. Returns how many moved.
     */
    suspend fun deleteFromCloud(items: List<LibraryItem>): Int {
        val chatId = noteChatId
        chatId?.let { library.requireWritable(it) }
        val telegramNow = if (chatId != null) telegram.telegramTimeMs() else null
        logClockGap(telegramNow)
        val at = CloudTrash.deletedAt(System.currentTimeMillis(), telegramNow)
        var moved = 0
        for (item in items) {
            val updated = store.changeTrashState(item.id, TrashLog.Op.DELETE, chatId) { CloudTrash.trash(it, at) }
            if (updated?.status != ItemStatus.Trashed) continue
            moved++
            AppLog.info("Moved an item to Recently Deleted")
        }
        if (moved > 0 && chatId != null) trashPacer.schedule()
        return moved
    }

    /**
     * Recovers the items, except ones being deleted right now or already gone (iOS `recover`). Needs a connection:
     * another device may have deleted them for good, and only Telegram can tell. Returns how many came back.
     */
    suspend fun recover(items: List<LibraryItem>): Int {
        val demo = isDemo()
        var chatId: Long? = null
        if (!demo) {
            chatId = library.chatId ?: throw TrashException.needsConnection
            library.requireWritable(chatId)
            telegram.telegramTimeMs(10_000) ?: throw TrashException.needsConnection
            try { withTimeout(120_000) { scanner.catchUp() } } catch (e: Exception) {
                if (e is CancellationException && e !is kotlinx.coroutines.TimeoutCancellationException) throw e
                throw TrashException.needsConnection
            }
        }
        val current = store.items(items.map { it.id })
        var gone = items.size - current.size
        // Recovered on another device in the meantime.
        var recovered = current.count { it.status != ItemStatus.Trashed }
        val trashed = current.filter { it.status == ItemStatus.Trashed }
        var inChannel = emptySet<Long>()
        if (chatId != null) {
            try { inChannel = withTimeout(120_000) { files.existingMessages(chatId, trashed.flatMap { it.allMessageIds }) } } catch (e: Exception) {
                if (e is CancellationException && e !is kotlinx.coroutines.TimeoutCancellationException) throw e
                throw TrashException.needsConnection
            }
        }
        var back = 0
        var busy = 0
        for (item in trashed) {
            if (chatId != null && TrashLog.allMessagesGone(item, inChannel)) {
                store.forgetDeletedItem(item)
                gone++
                continue
            }
            // Holding the gate means a deletion can't start on this item while it's recovered, and the other way round.
            val done = gate.ifNotDeleting(item.id) {
                store.changeTrashState(item.id, TrashLog.Op.RECOVER, chatId) { TrashLog.recover(it) }
            }
            if (done) { back++; recovered++ } else busy++
        }
        if (back > 0 && chatId != null) trashPacer.schedule()
        AppLog.info("Recovered $recovered items from Recently Deleted, $gone were already gone")
        if (gone > 0) throw TrashException.alreadyGone(gone)
        if (busy > 0) throw TrashException.alreadyDeleting
        return recovered
    }

    /** Backing up again a photo still in Recently Deleted is recovering it (iOS `BackupEngine` chosen photos). */
    suspend fun recoverForBackup(item: LibraryItem): Boolean {
        val chatId = noteChatId
        chatId?.let { library.requireWritable(it) }
        val done = gate.ifNotDeleting(item.id) {
            store.changeTrashState(item.id, TrashLog.Op.RECOVER, chatId) { TrashLog.recover(it) }
        }
        if (done && chatId != null) trashPacer.schedule()
        return done
    }

    /**
     * Deletes every message of the trashed items from the channel (iOS `deletePermanently`). Only items still in
     * Recently Deleted when their turn comes go ([expiredBy] for the 30-day cleanup: only items expired by then);
     * anything recovered meanwhile is left alone. In batches, paced like uploads.
     */
    suspend fun deletePermanently(items: List<LibraryItem>, expiredBy: Long? = null) {
        if (items.isEmpty()) return
        val chatId = if (isDemo()) null else (library.chatId ?: throw LibraryException.noLibrary).also { library.requireWritable(it) }
        CloudTrash.deleteBatches(items).forEachIndexed { index, batch ->
            if (index > 0 && chatId != null) delay(BackupEngine.UPLOAD_SPACING_MS)
            while (true) {
                try {
                    deleteBatch(batch, chatId, expiredBy)
                    break
                } catch (e: TelegramException) {
                    // The gate is released while waiting, so Recover still works, and the batch is checked again afterwards.
                    val wait = TelegramErrors.floodWaitSeconds(e.message) ?: throw e
                    delay(wait * 1000L)
                }
            }
        }
        // Nothing stays behind: the notes for these photos go with them.
        removeFinishedTrashNotes()
    }

    private suspend fun deleteBatch(batch: List<LibraryItem>, chatId: Long?, expiredBy: Long?) {
        // Read again under the gate: the user may have recovered these since the list was made.
        val claimed = batch.mapNotNull { item ->
            gate.claim(item.id) {
                store.item(item.id)?.takeIf { it.status == ItemStatus.Trashed && (expiredBy == null || CloudTrash.isExpired(it, expiredBy)) }
            }
        }
        try {
            if (claimed.isEmpty()) return
            if (chatId != null) uploads.deleteMessages(chatId, claimed.flatMap { it.allMessageIds })
            for (item in claimed) {
                store.forgetDeletedItem(item)
                AppLog.info("Deleted an item from your Telegram library")
            }
            // A delete note that hadn't gone yet has nothing left to say.
            store.clearTrashChanges(TrashLog.Op.DELETE, claimed.map { it.id })
        } finally {
            claimed.forEach { gate.release(it.id) }
        }
    }

    /**
     * Deletes items whose 30 days are over (iOS `emptyExpiredTrash`). Keeps everything unless Telegram's time is known,
     * this phone is up to date, and a note in the channel still says the item was deleted. Retried next time on failure.
     */
    suspend fun emptyExpiredTrash() {
        if (isDemo()) {
            val now = System.currentTimeMillis()
            runCatching { deletePermanently(CloudTrash.items(store.allItems()).filter { CloudTrash.isExpired(it, now) }, now) }
            return
        }
        if (!ready) return
        // Nothing due by this phone's clock means nothing is due at all: the earlier clock decides.
        if (store.items(ItemStatus.Trashed).none { CloudTrash.isExpired(it, System.currentTimeMillis()) }) return
        val chatId = writableChat() ?: return
        val telegramNow = telegram.telegramTimeMs(30_000)
        logClockGap(telegramNow)
        val now = CloudTrash.expiryClock(System.currentTimeMillis(), telegramNow) ?: run {
            AppLog.info("Kept Recently Deleted as it is: Telegram's time isn't known yet")
            return
        }
        try {
            // A recover on another device must be seen before anything goes. Items no note keeps here follow Telegram.
            scanner.catchUp()
            if (library.chatId != chatId) return
            followTelegram()
            val newest = TrashLog.latest(store.trashNotes())
            val waiting = store.queuedTrashChanges(chatId).values.flatten().toHashSet()
            val due = store.items(ItemStatus.Trashed).filter { CloudTrash.isExpired(it, now) && TrashLog.mayPurge(it, newest[it.id], waiting) }
            deletePermanently(due, expiredBy = now)
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            AppLog.warn("Emptying Recently Deleted failed", e)
        }
    }

    private fun logClockGap(telegramMs: Long?) {
        if (telegramMs == null) AppLog.info("Telegram's time isn't known yet")
        else AppLog.info("Telegram's time differs from this phone by ${(System.currentTimeMillis() - telegramMs) / 1000} s")
    }

    // MARK: Opening and following other devices

    /**
     * When Lelvo opens (iOS `TrashSync.onOpen`): read what the other devices did, send what's waiting, tidy up notes,
     * match favorites with the phone and do the 30-day cleanup. Not more than once in 5 minutes; while Lelvo runs, live
     * updates bring every change.
     */
    fun onOpen(force: Boolean = false, afterScan: suspend () -> Unit = {}) {
        if (!ready) { if (isDemo()) scope.launch { emptyExpiredTrash() }; return }
        // At launch Telegram isn't ready yet: the app's own catch-up runs this once it is (`force`).
        if (!force && telegram.auth.value != AuthStep.Ready) return
        scope.launch {
            if ((!force && System.currentTimeMillis() - lastOpenCheck < OPEN_GAP_MS) || !opening.tryLock()) return@launch
            try {
                if (withTimeoutOrNull(30_000) { telegram.auth.first { it == AuthStep.Ready } } == null) return@launch
                try { scanner.catchUp() } catch (e: Exception) {
                    if (e is CancellationException) throw e
                    AppLog.warn("Couldn't check for changes from other devices", e)
                    // Also when that stopped early: changes waiting from last time still go.
                    sendMeta()
                    return@launch
                }
                lastOpenCheck = System.currentTimeMillis()
                runCatching { afterScan() }
                afterCatchUp()
            } finally {
                opening.unlock()
            }
        }
    }

    /** Lelvo went to the background: send what's waiting without waiting for the pacing. */
    fun onBackground() {
        if (!ready) return
        scope.launch { sendTrash(); sendMeta() }
    }

    /**
     * Everything that needs the channel just read (iOS `afterCatchUp`): on open and after Re-scan. Returns how many
     * favorites were matched with the phone.
     */
    suspend fun afterCatchUp(): Int {
        val steps = ArrayList<String>()
        var mark = System.currentTimeMillis()
        fun step(name: String) {
            val now = System.currentTimeMillis()
            steps += "$name ${(now - mark) / 100 / 10.0} s"
            mark = now
        }
        try { followTelegram() } catch (e: Exception) {
            if (e is CancellationException) throw e
            AppLog.warn("Couldn't check Recently Deleted with Telegram", e)
            return 0
        }
        step("follow")
        sendTrash()
        step("send")
        removeFinishedTrashNotes()
        step("tidy")
        // The channel was just read, so favorites and albums can send, tidy up and compact safely.
        sendMeta()
        compactIfLong()
        removeFinishedMetaNotes()
        step("favorites and albums")
        val matched = matchPhoneFavorites()
        step("phone")
        emptyExpiredTrash()
        step("empty")
        AppLog.info("Notes in your Telegram library: ${store.metaNotes().size} favorites and albums, ${store.trashNotes().size} Recently Deleted (${steps.joinToString(", ")})")
        return matched
    }

    /**
     * Makes Recently Deleted match the channel (iOS `followTelegram`). Only right after catching up, so a note this
     * phone hasn't read can't be missed. Items from before notes existed get one, once. After that an item no note
     * keeps here follows Telegram: messages gone means deleted for good, messages still there means recovered.
     */
    suspend fun followTelegram() {
        val chatId = library.chatId ?: return
        if (scanner.needsFullScan()) return
        // This order, as a send may finish meanwhile: an item's change is queued with it, and its note is stored before
        // the row goes. So each item read here is either waiting or its note is in `notes`.
        val trashed = store.items(ItemStatus.Trashed)
        val waiting = store.queuedTrashChanges(chatId).values.flatten().toHashSet()
        var notes = store.trashNotes()
        val oldKey = "trashNotesForOldItemsAdded.$chatId"
        if (!prefs.getBoolean(oldKey, false)) {
            // Only where this build may write: a note can't go to the real library before the gate.
            if (writableChat() != chatId) return
            val old = TrashLog.itemsNeedingANote(trashed, notes, waiting)
            if (old.isNotEmpty()) {
                AppLog.info("Adding ${old.size} items already in Recently Deleted to your other devices")
                store.queueTrashChange(TrashLog.Op.DELETE, old.map { it.id }, chatId)
                trashPacer.schedule()
            }
            prefs.edit().putBoolean(oldKey, true).apply()
            return
        }
        if (trashed.isEmpty()) return
        val toConfirm = TrashLog.notesToConfirm(trashed, notes, waiting)
        val stillThere = files.existingMessages(chatId, toConfirm)
        // Switched library while asking: the index is the other library's now.
        if (library.chatId != chatId) return
        val removed = toConfirm - stillThere
        if (removed.isNotEmpty()) {
            store.removeTrashNotes(removed)
            notes = notes.filter { it.messageId !in removed }
        }
        val uncovered = TrashLog.uncovered(trashed, notes, notes.map { it.messageId }.toSet(), waiting)
        if (uncovered.isEmpty()) return
        val inChannel = files.existingMessages(chatId, uncovered.flatMap { it.allMessageIds })
        if (library.chatId != chatId) return
        // The user may have acted during the wait for Telegram: their change is the newer one.
        val waitingNow = store.queuedTrashChanges(chatId).values.flatten().toHashSet()
        var gone = 0
        var back = 0
        for (item in uncovered) {
            if (item.id in waitingNow || item.allMessageIds.isEmpty()) continue
            if (TrashLog.allMessagesGone(item, inChannel)) {
                store.forgetDeletedItem(item)
                gone++
            } else if (gate.ifNotDeleting(item.id) { store.update(item.id) { TrashLog.recover(it) } }) {
                back++
            }
        }
        AppLog.info("Recently Deleted followed Telegram: $gone deleted for good, $back back in your library")
    }

    /** Another device finished with a note while Lelvo is open (iOS `followOtherDevice`). */
    private fun followOtherDevice() {
        if (!ready) return
        scope.launch {
            try {
                scanner.scan(full = false)
                followTelegram()
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                AppLog.warn("Couldn't follow another device's change", e)
                return@launch
            }
            matchPhoneFavorites()
        }
    }

    /** Before leaving a library or signing out: give waiting changes a moment (iOS `sendBeforeLeaving`). */
    suspend fun sendBeforeLeaving() {
        withTimeoutOrNull(5_000) { sendTrash(); sendMeta() }
    }

    // MARK: Sending

    /** Sends every waiting Recently Deleted change, one note per kind (iOS `TrashSync.send`). */
    private suspend fun sendTrash() {
        if (!ready) return
        trashSend.withLock {
            val chatId = library.chatId ?: return
            val queued = store.queuedTrashChanges(chatId)
            if (queued.isEmpty()) return
            if (queued[TrashLog.Op.GONE] != null) store.dropRetiredTrashChanges()
            var failed = false
            for (op in listOf(TrashLog.Op.DELETE, TrashLog.Op.RECOVER)) {
                val ids = queued[op]?.takeIf { it.isNotEmpty() } ?: continue
                try {
                    engine.withNoteSlot { sendTrashNote(op, ids, chatId) }
                    trashPacer.sent()
                    store.clearTrashChanges(op, ids)
                } catch (e: Exception) {
                    if (e is CancellationException) throw e
                    AppLog.warn("Recently Deleted note not sent, will try again: ${e.message}")
                    failed = true
                }
            }
            // Every device now uses the date Telegram put on the note, this phone too.
            runCatching { scanner.applyTrashNotesNow() }
            removeFinishedTrashNotes()
            if (failed) trashPacer.failed()
            if (failed || store.queuedTrashChanges(chatId).isNotEmpty()) trashPacer.schedule()
        }
    }

    /** Sends every waiting favorite and album change (iOS `MetaSync.send`). */
    private suspend fun sendMeta() {
        if (!ready) return
        metaSend.withLock {
            val chatId = library.chatId ?: return
            val queued = store.queuedMetaChanges(chatId)
            if (queued.isEmpty()) return
            var failed = false
            for (body in MetaLog.bodies(queued)) {
                try {
                    engine.withNoteSlot { sendMetaNote(body, chatId) }
                    metaPacer.sent()
                    body.key?.let { store.clearMetaChange(body.ids, it, body.op.value) }
                } catch (e: Exception) {
                    if (e is CancellationException) throw e
                    AppLog.warn("Favorites and albums note not sent, will try again: ${e.message}")
                    failed = true
                    break
                }
            }
            // Only the items just sent: the rest already follow their notes.
            runCatching { scanner.applyMetaNotesNow(queued.keys) }
            removeFinishedMetaNotes()
            if (failed) metaPacer.failed()
            if (failed || store.queuedMetaChanges(chatId).isNotEmpty()) metaPacer.schedule()
        }
    }

    private suspend fun sendTrashNote(op: TrashLog.Op, ids: List<String>, chatId: Long) {
        val plain = TrashLog.encode(TrashLog.Body(op, ids))
        val message = sendNote(chatId, plain, "recently-deleted.cge") { key -> TrashLog.caption(NoteCaption.of(plain, ids.size), key) }
        store.addTrashNote(TrashLog.Note(message.first, message.second, op, ids))
        AppLog.info("Sent a Recently Deleted note: ${op.wire}, ${ids.size} items")
    }

    private suspend fun sendMetaNote(body: MetaLog.Body, chatId: Long) {
        val plain = MetaLog.encode(body)
        val message = sendNote(chatId, plain, "favorites-albums.cge") { key -> MetaLog.caption(NoteCaption.of(plain, body.ids.size), key) }
        store.addMetaNote(MetaLog.Note(message.first, message.second, body.op, body.ids, body.album))
        AppLog.info("Sent a favorites and albums note: ${body.op.wire}, ${body.ids.size} items")
    }

    /**
     * Sends one note document, CGFE-encrypted, and returns its message id and Telegram date (seconds). Only a note
     * Telegram confirmed with the expected size counts (iOS `sendTrashNote`, `sendMetaNote`).
     */
    private suspend fun sendNote(chatId: Long, plain: ByteArray, name: String, caption: (ByteArray) -> String): Pair<Long, Long> =
        withContext(Dispatchers.IO) {
            // These ids belong to that library; a switch while this waited must not send them to the new one.
            if (library.chatId != chatId) throw LibraryException.noLibrary
            library.requireWritable(chatId)
            val keys = library.keys ?: throw LibraryException.wrongPassphrase
            val dir = File(staging, UUID.randomUUID().toString()).apply { mkdirs() }
            try {
                val file = File(dir, name)
                file.writeBytes(FileCrypto.encrypt(plain, keys.master))
                val size = file.length()
                val message = uploads.sendDocument(chatId, file, caption(keys.captionKey))
                val doc = (message.content as? org.drinkless.tdlib.TdApi.MessageDocument)?.document?.document
                if (doc == null || doc.size != size) {
                    runCatching { uploads.deleteMessages(chatId, listOf(message.id)) }
                    throw TelegramException(0, "The note wasn't stored whole")
                }
                // Switched during the send: the index now belongs to the other library, whose message ids mean something else.
                if (library.chatId != chatId) throw LibraryException.noLibrary
                uploads.forgetLocalCopy(doc.id)
                message.id to message.date.toLong()
            } finally {
                dir.deleteRecursively()
            }
        }

    // MARK: Tidying up the channel

    /** Deletes every Recently Deleted note that has done its job, in batches (iOS `removeFinishedNotes`). */
    private suspend fun removeFinishedTrashNotes() {
        if (!ready || !trashCleaning.tryLock()) return
        try {
            val notes = store.trashNotes()
            if (notes.isEmpty() || scanner.needsFullScan()) return
            val chatId = writableChat() ?: return
            val known = store.allItems().map { it.id }.toHashSet()
            deleteNotes(chatId, TrashLog.notesToRemove(notes, known).map { it.messageId }, "Recently Deleted") { store.removeTrashNotes(it) }
        } finally {
            trashCleaning.unlock()
        }
    }

    /** Deletes favorites and albums notes that no longer decide anything (iOS `MetaSync.removeFinishedNotes`). */
    private suspend fun removeFinishedMetaNotes() {
        if (!ready || !metaCleaning.tryLock()) return
        try {
            val notes = store.metaNotes()
            if (notes.isEmpty() || scanner.needsFullScan()) return
            val chatId = writableChat() ?: return
            val now = System.currentTimeMillis() / 1000
            // The whole index only when a note is old enough for its items to have been deleted for good.
            val anyOld = notes.any { now - it.date > MetaLog.GONE_AFTER_SECONDS }
            val known = if (anyOld) store.allItems().map { it.id }.toHashSet().takeIf { it.isNotEmpty() } else null
            deleteNotes(chatId, MetaLog.notesToRemove(notes, known, now).map { it.messageId }, "favorites and albums") { store.removeMetaNotes(it) }
        } finally {
            metaCleaning.unlock()
        }
    }

    private suspend fun deleteNotes(chatId: Long, finished: List<Long>, what: String, forget: suspend (List<Long>) -> Unit) {
        finished.chunked(CloudTrash.MAX_MESSAGES_PER_DELETE).forEachIndexed { i, batch ->
            if (i > 0) delay(BackupEngine.UPLOAD_SPACING_MS)
            while (true) {
                try {
                    uploads.deleteMessages(chatId, batch)
                    forget(batch)
                    AppLog.info("Removed ${batch.size} finished $what notes")
                    break
                } catch (e: TelegramException) {
                    val wait = TelegramErrors.floodWaitSeconds(e.message)
                    if (wait == null) { AppLog.warn("$what notes not removed, will try again: ${e.message}"); return }
                    delay(wait * 1000L)
                }
            }
        }
    }

    /**
     * With many notes left, sends the current state as fresh notes, which makes every older one removable (iOS
     * `compactIfLong`). Only right after the channel was read, so it can't override a note it hasn't seen.
     */
    private suspend fun compactIfLong() {
        val chatId = library.chatId ?: return
        if (store.metaNotes().size <= MetaLog.COMPACT_ABOVE || store.queuedMetaChanges(chatId).isNotEmpty()) return
        if (writableChat() != chatId) return
        metaSend.withLock {
            // Read the newest messages right before, so a change another device just sent is part of the state written.
            runCatching { scanner.scan(full = false) }.getOrNull() ?: return
            val notes = store.metaNotes()
            val known = store.allItems().map { it.id }.toHashSet()
            if (known.isEmpty()) return
            val fresh = MetaLog.compacted(notes, known)
            // Only when it really shrinks the channel, and not after skipping a note this version can't read.
            if (fresh.size * 2 >= notes.size || scanner.skippedMetaNotes) return
            for (body in fresh) {
                try {
                    engine.withNoteSlot { sendMetaNote(body, chatId) }
                } catch (e: Exception) {
                    if (e is CancellationException) throw e
                    AppLog.warn("Favorites and albums notes not compacted, will try again: ${e.message}")
                    return
                }
            }
            metaPacer.sent()
            AppLog.info("Compacted ${notes.size} favorites and albums notes")
        }
    }

    // MARK: Favorites on the phone

    /** Favorites the Telegram library wants on the phone; the app asks the system once, with Lelvo on screen. */
    data class PhoneFavoriteRequest(val value: Boolean, val localIds: List<String>, val itemIds: List<String>)

    private val _phoneRequests = MutableStateFlow<List<PhoneFavoriteRequest>>(emptyList())
    val phoneRequests: StateFlow<List<PhoneFavoriteRequest>> = _phoneRequests
    @Volatile private var phoneDeclined = false

    /**
     * Keeps the favorite on the phone and in the Telegram library the same for backed-up items on this phone (iOS
     * `PhotosFavoriteSync`). Only after the channel was read: a note not read yet would look like a change on the
     * phone. Android can't change a favorite without the system asking, so changes for the phone wait in
     * [phoneRequests] until the app shows the prompt. Returns how many were sent as notes.
     */
    suspend fun matchPhoneFavorites(): Int {
        if (!ready || scanner.needsFullScan()) return 0
        val chatId = writableChat() ?: return 0
        val phoneFavorites = photos.favoriteIds() ?: return 0
        val items = store.items(ItemStatus.BackedUp).filter { it.localId != null }
        val lastSeen = store.phoneFavorites()
        val latest = MetaLog.latest(store.metaNotes())
        val waiting = store.queuedMetaChanges(chatId)
        val remember = HashMap<String, Boolean?>()
        val linked = items.map { it.id }.toHashSet()
        lastSeen.keys.filter { it !in linked }.forEach { remember[it] = null }
        val toPhone = HashMap<Boolean, MutableList<LibraryItem>>()
        val toNote = HashMap<Boolean, MutableList<LibraryItem>>()
        for (item in items) {
            val phone = item.localId!! in phoneFavorites
            val noteDecides = latest[item.id]?.containsKey(MetaLog.Key.Favorite) == true || waiting[item.id]?.containsKey(MetaLog.Key.Favorite) == true
            when (val d = PhotosFavorite.decide(phone, lastSeen[item.id], PhotosFavorite.libraryValue(item.favorite, noteDecides), noteDecides)) {
                PhotosFavorite.Decision.Remember -> if (lastSeen[item.id] != phone) remember[item.id] = phone
                is PhotosFavorite.Decision.SetOnPhone -> toPhone.getOrPut(d.value) { ArrayList() } += item
                is PhotosFavorite.Decision.SendNote -> toNote.getOrPut(d.value) { ArrayList() } += item
            }
        }
        var sent = 0
        for ((value, group) in toNote) {
            // Only photos really on the phone with that value: a link to a photo that's gone must not unfavorite it everywhere.
            val current = photos.favorites(group.mapNotNull { it.localId })
            val ready = group.filter { current[it.localId] == value }
            if (ready.isEmpty()) continue
            change(ready, MetaLog.Key.Favorite, value)
            ready.forEach { remember[it.id] = value }
            sent += ready.size
        }
        store.setPhoneFavorites(remember)
        val requests = toPhone.mapNotNull { (value, group) ->
            val current = photos.favorites(group.mapNotNull { it.localId })
            val ready = group.filter { current[it.localId] == !value }
            if (ready.isEmpty()) null else PhoneFavoriteRequest(value, ready.mapNotNull { it.localId }, ready.map { it.id })
        }
        // Declined once since Lelvo started: not again until the next start, or it would ask on every open.
        _phoneRequests.value = if (phoneDeclined) emptyList() else requests
        if (sent > 0 || requests.isNotEmpty()) {
            AppLog.info("Favorites matched with the phone: ${requests.sumOf { it.localIds.size }} to change on the phone, $sent sent to your other devices")
        }
        return sent
    }

    /** The system prompt for [request] closed: remember the phone's value when it was changed. */
    suspend fun phoneRequestFinished(request: PhoneFavoriteRequest, changed: Boolean) {
        _phoneRequests.value = _phoneRequests.value - request
        if (!changed) { phoneDeclined = true; _phoneRequests.value = emptyList(); return }
        store.setPhoneFavorites(request.itemIds.associateWith { request.value })
        AppLog.info("Favorites matched with the phone: ${request.localIds.size} changed on the phone")
    }

    /** The user changed favorites on the phone through Lelvo: remember it, so the next check doesn't read it as theirs from elsewhere. */
    suspend fun rememberPhoneFavorites(itemIds: List<String>, value: Boolean) = store.setPhoneFavorites(itemIds.associateWith { value })

    // MARK: Pacing

    /**
     * 5 s so a burst shares one note, at least 10 s between notes, a minute after a failure (iOS `TrashLog.sendDelay`).
     */
    private inner class Pacer(private val what: String, private val send: suspend () -> Unit) {
        @Volatile private var lastSent: Long? = null
        @Volatile private var scheduled = false

        fun schedule() {
            val delayMs = synchronized(this) {
                if (scheduled) return
                scheduled = true
                TrashLog.sendDelayMs(lastSent, System.currentTimeMillis())
            }
            scope.launch {
                delay(delayMs)
                synchronized(this@Pacer) { scheduled = false }
                try { send() } catch (e: Exception) {
                    if (e is CancellationException) throw e
                    AppLog.warn("Sending $what notes failed", e)
                }
            }
        }

        fun sent() { lastSent = System.currentTimeMillis() }
        fun failed() { lastSent = TrashLog.lastSentAfterFailureMs(System.currentTimeMillis()) }
    }

    private companion object {
        const val OPEN_GAP_MS = 5 * 60_000L
    }
}

/**
 * Keeps recovering and permanently deleting the same item from overlapping (iOS `TrashGate`): the 30-day cleanup
 * runs in the background while the user can tap Recover.
 */
internal class TrashGate {
    private val deleting = HashSet<String>()
    private val lock = Mutex()

    /** Marks [id] as being deleted when [check] (run under the lock) returns an item; null if it's taken or gone. */
    suspend fun <T> claim(id: String, check: suspend () -> T?): T? = lock.withLock {
        if (id in deleting) return@withLock null
        check()?.also { deleting += id }
    }

    suspend fun release(id: String) = lock.withLock { deleting -= id }

    /** Runs [body] unless [id] is being deleted. Returns whether it ran. */
    suspend fun ifNotDeleting(id: String, body: suspend () -> Unit): Boolean = lock.withLock {
        if (id in deleting) return@withLock false
        body()
        true
    }
}
