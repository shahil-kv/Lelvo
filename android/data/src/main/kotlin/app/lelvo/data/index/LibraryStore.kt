package app.lelvo.data.index

import app.lelvo.core.index.ItemExtras
import app.lelvo.core.index.ItemKind
import app.lelvo.core.index.ItemStatus
import app.lelvo.core.index.LibraryItem
import androidx.room.withTransaction
import app.lelvo.core.format.MetaLog
import app.lelvo.core.format.NoteIds
import app.lelvo.core.format.TrashLog
import kotlinx.coroutines.Dispatchers
import app.lelvo.core.support.AppLog
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.shareIn
import kotlinx.coroutines.flow.transform

/** The local index (iOS `LibraryStore`): every call runs off the main thread. */
class LibraryStore(private val db: IndexDatabase) {
    private val dao = db.items()
    private val notes = db.notes()

    private val scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + Dispatchers.Default)

    /**
     * Every item, updated after changes. One read shared by every screen, at most twice a second: a backup changes
     * the index several times a second, and each screen reading all 30,000 rows on every change froze the app.
     */
    private val shared: Flow<List<LibraryItem>> = db.invalidationTracker.createFlow("items")
        .throttled(500)
        .conflate()
        .transform {
            // A failed read used to kill the app: Android throws from the cursor while a backup is also holding
            // every queued row, and that exception reached the screen. Keep the last good list instead.
            try {
                val rows = dao.allNow().map(::toItem)
                emit(rows)
                // A backup changes the index every second or two. Re-reading tens of thousands of rows twice a second
                // kept the CPU and garbage collector busy and made scrolling stutter; a large library refreshes less often.
                if (rows.size > LARGE_LIBRARY) kotlinx.coroutines.delay(1_500)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                AppLog.error("Library index read failed: ${e.javaClass.simpleName}")
            }
        }
        .flowOn(Dispatchers.Default)
        .shareIn(scope, SharingStarted.WhileSubscribed(stopTimeoutMillis = 5_000), replay = 1)

    fun items(): Flow<List<LibraryItem>> = shared

    /** The index changed. Emits at once, then at most twice a second, and never reads a row. */
    fun changes(): Flow<Unit> = flow {
        emit(Unit)
        db.invalidationTracker.createFlow("items").collect { emit(Unit) }
    }.throttled(500).flowOn(Dispatchers.IO)

    /** How many rows the index holds, without loading them. */
    fun countFlow(): Flow<Int> = changes().map { dao.countAll() }.flowOn(Dispatchers.IO)

    fun trashedCountFlow(): Flow<Int> = changes().map { dao.trashedCount() }.flowOn(Dispatchers.IO)

    /** Items in Recently Deleted only, updated when the index changes, without reading the whole library. */
    fun trashedItems(): Flow<List<LibraryItem>> = changes().map { items(ItemStatus.Trashed) }.flowOn(Dispatchers.IO)

    suspend fun item(id: String): LibraryItem? = dao.item(id)?.let(::toItem)
    suspend fun upsert(items: List<LibraryItem>) = dao.upsert(items.map(::toRow))
    suspend fun backedUpCount(): Int = dao.backedUpCount()
    suspend fun allItems(): List<LibraryItem> = dao.allNow().map(::toItem)
    suspend fun allIds(): Set<String> = dao.ids().toHashSet()
    suspend fun lockedIds(): Set<String> = dao.lockedIds().toHashSet()
    suspend fun lockedInCloud(): List<LibraryItem> = dao.lockedInCloud().map(::toItem)
    suspend fun lockedLocalIds(): Set<String> = dao.lockedLocalIds().toHashSet()
    suspend fun unlinkedBackedUp(): List<LibraryItem> = dao.unlinkedBackedUp().map(::toItem)
    suspend fun linkedLocalIds(): Set<String> = dao.linkedLocalIds().toHashSet()
    suspend fun favoriteRefs(): List<FavoriteRef> = dao.favoriteRefs()
    suspend fun hasCloudParts(): Boolean = dao.withPartsCount() > 0

    /**
     * Backed-up items linked to a phone photo, [pageSize] rows at a time, until [block] returns false. A large
     * library (tens of thousands of rows with their parts) never sits in memory at once.
     */
    suspend fun forEachBackedUpOnPhone(pageSize: Int = 500, block: suspend (List<LibraryItem>) -> Boolean) {
        var after = ""
        while (true) {
            val page = dao.backedUpOnPhonePage(after, pageSize)
            if (page.isEmpty() || !block(page.map(::toItem))) return
            after = page.last().id
        }
    }

    /** Chunked: Android 10's SQLite allows 999 values in one query. */
    suspend fun items(ids: Collection<String>): List<LibraryItem> = ids.chunked(500).flatMap { dao.items(it) }.map(::toItem)

    /** Items whose photo is one of these MediaStore ids. `items` looks up the row id, not the phone id. */
    suspend fun itemsForPhone(localIds: Collection<String>): List<LibraryItem> =
        localIds.distinct().chunked(500).flatMap { dao.withLocalIds(it) }.map(::toItem)

    suspend fun delete(id: String) = dao.delete(id)

    suspend fun items(status: ItemStatus): List<LibraryItem> = dao.withStatus(status.code).map(::toItem)

    /** What the Backup tab counts, without loading the queue. */
    data class QueueTotals(
        val uploadable: Int, val chosenUploadable: Int, val stranded: Int, val failed: Int, val retryableFailed: Int,
    )

    suspend fun queueTotals() = QueueTotals(
        dao.uploadableCount(), dao.chosenUploadableCount(), dao.strandedCount(), dao.failedCount(), dao.retryableFailedCount(),
    )

    /** Queued ids in upload order. The run holds these ids, and loads one full item when that item's turn comes. */
    suspend fun queuedIdsInOrder(onlyChosen: Boolean = false): List<String> =
        if (onlyChosen) dao.chosenQueuedIdsInOrder() else dao.queuedIdsInOrder()

    suspend fun queuedOnPhone(): List<Pair<String, String>> = dao.queuedLocalIds().map { it.id to it.localId }

    suspend fun queuedWithoutPhone(): List<LibraryItem> = dao.queuedWithoutPhone().map(::toItem)

    suspend fun remainingQueued(onlyChosen: Boolean): Int = if (onlyChosen) dao.chosenQueuedCount() else dao.queuedWithPhoneCount()

    suspend fun trashedLocalIds(): List<String> = dao.trashedLocalIds()

    suspend fun backedUpRefs(): List<BackedUpRef> = dao.backedUpRefs()

    suspend fun coordinates(): List<LatLon> = dao.coordinates()
    suspend fun items(sha256: String): List<LibraryItem> = if (sha256.isEmpty()) emptyList() else dao.withHash(sha256).map(::toItem)
    suspend fun itemForPhone(localId: String): LibraryItem? = dao.withLocalId(localId)?.let(::toItem)

    /** Deletes the row only while it is still queued: an upload may have started since it was read. */
    suspend fun deleteIfQueued(id: String): Boolean = dao.deleteIfQueued(id) > 0

    /** Reads, changes and writes one item in a transaction; nothing when it's gone. */
    suspend fun update(id: String, change: (LibraryItem) -> LibraryItem): LibraryItem? = db.withTransaction {
        val now = dao.item(id)?.let(::toItem) ?: return@withTransaction null
        change(now).also { dao.upsert(listOf(toRow(it))) }
    }

    /**
     * Phone ids the index knows in any state, aliases included (another phone photo with the same bytes as a
     * backed-up one, iOS `aliases`). Kept in `meta`, which goes with the index.
     */
    suspend fun knownLocalIds(): Set<String> = (dao.localIds() + notes.aliasKeys().map { it.removePrefix(ALIAS) }).toHashSet()

    /** Phone id → the item it's a copy of. */
    suspend fun aliases(): Map<String, String> = notes.aliasRows().associate { it.key.removePrefix(ALIAS) to it.value }

    suspend fun removeAlias(localId: String) = notes.removeMeta(ALIAS + localId)

    suspend fun addAlias(localId: String, itemId: String) = notes.setMeta(MetaRow(ALIAS + localId, itemId))

    /** Phone ids deleted from the backup on purpose (`l:` keys of `no_backup`). */
    suspend fun offBackupLocalIds(): Set<String> = notes.noBackupKeys().filter { it.startsWith("l:") }.map { it.removePrefix("l:") }.toHashSet()

    /** Same bytes as a photo deleted from the backup for good (iOS `isOffBackup`). */
    suspend fun isOffBackup(sha256: String, editHash: String?): Boolean =
        sha256.isNotEmpty() && isNoBackup("h:" + sha256 + (editHash?.let { "|$it" } ?: ""))

    /** This phone photo stays on the phone only until the user backs it up (iOS `keepOffBackup`). */
    suspend fun keepOffBackup(localId: String) = notes.addNoBackup(listOf(NoBackupRow("l:$localId")))

    /** The user chose to back it up after all (iOS `allowBackup`). */
    suspend fun allowBackup(localId: String) = notes.removeNoBackup("l:$localId")

    /** A phone photo set aside as unreadable, as it was when its file changed last ([modifiedAt], the same value the item keeps; null when unknown). Replaces an earlier entry. */
    suspend fun ignoreAsset(localId: String, reason: String, modifiedAt: Long?, now: Long = System.currentTimeMillis()) =
        notes.ignoreAsset(IgnoredAssetRow(localId, reason, modifiedAt?.toString() ?: "", now / 1000))

    suspend fun ignoredAssets(): List<IgnoredAssetRow> = notes.ignoredAssets()

    suspend fun ignoredAssetCount(): Int = notes.ignoredAssetCount()

    /** True when the photo is set aside and hasn't changed since: one that changed is tried again. */
    suspend fun isIgnored(localId: String, modifiedAt: Long?): Boolean =
        notes.ignoredModified(localId)?.let { it == (modifiedAt?.toString() ?: "") } ?: false

    /** The phone ids among [items] whose photo is set aside and hasn't changed since, from one read (iOS `ignoredAmong`). */
    suspend fun ignoredAmong(items: List<LibraryItem>): Set<String> {
        val stored = notes.ignoredAssets().associate { it.localId to it.modified }
        if (stored.isEmpty()) return emptySet()
        return items.mapNotNull { item ->
            val id = item.localId ?: return@mapNotNull null
            id.takeIf { stored[it] == (item.assetModifiedAt?.toString() ?: "") }
        }.toHashSet()
    }

    suspend fun unignoreAsset(localId: String) = notes.unignoreAsset(localId)
    suspend fun unignoreAllAssets() = notes.unignoreAllAssets()

    /** Everything in the index: items, notes, meta and the off-backup list (a new library or a reset). */
    suspend fun deleteAll() = db.withTransaction {
        dao.deleteAll(); notes.clearTrashNotes(); notes.clearMetaNotes(); notes.clearMeta(); notes.clearNoBackup(); notes.unignoreAllAssets()
        notes.clearTrashOutbox(); notes.clearMetaOutbox(); notes.clearPhoneFavorites()
    }

    /**
     * Removes an item whose cloud copy is gone. A photo still on this phone stays there and isn't backed up again by
     * itself, nor is another copy of it (iOS `forgetDeletedItem`; the same keys).
     */
    suspend fun forgetDeletedItem(item: LibraryItem) {
        val keys = buildList {
            item.localId?.let { add("l:$it") }
            if (item.sha256.isNotEmpty()) add("h:" + item.sha256 + (item.roleHashes["e"]?.let { "|$it" } ?: ""))
        }
        db.withTransaction {
            notes.addNoBackup(keys.map(::NoBackupRow))
            dao.delete(item.id)
        }
    }

    suspend fun isNoBackup(key: String): Boolean = notes.isNoBackup(key) > 0

    /** Every key of the off-backup list, to keep with the library's choices (iOS `offBackupKeys`). */
    suspend fun noBackupKeys(): List<String> = notes.noBackupKeys()

    suspend fun restoreNoBackupKeys(keys: Collection<String>) = keys.chunked(500).forEach { c -> notes.addNoBackup(c.map(::NoBackupRow)) }

    /** Puts waiting changes back after a library switch (iOS `queueMetaChanges`): sent like any other. */
    suspend fun queueMetaChanges(changes: Map<String, Map<MetaLog.Key, Boolean>>, chatId: Long) = db.withTransaction {
        changes.flatMap { (id, keys) -> keys.map { (k, v) -> MetaOutboxRow(id, k.stored, chatId, v) } }.chunked(500).forEach { notes.queueMeta(it) }
    }

    suspend fun trashNotes(): List<TrashLog.Note> = notes.trashNotes().mapNotNull { r ->
        TrashLog.Note(r.messageId, r.date, TrashLog.Op.of(r.op) ?: return@mapNotNull null, decodeIds(r.ids))
    }
    suspend fun addTrashNote(n: TrashLog.Note) = notes.addTrashNote(TrashNoteRow(n.messageId, n.date, n.op.wire, encodeIds(n.ids)))
    suspend fun removeTrashNotes(ids: Collection<Long>) = ids.chunked(500).forEach { notes.removeTrashNotes(it) }

    suspend fun metaNotes(): List<MetaLog.Note> = notes.metaNotes().mapNotNull { r ->
        MetaLog.Note(r.messageId, r.date, MetaLog.Op.of(r.op) ?: return@mapNotNull null, decodeIds(r.ids), r.album)
    }
    suspend fun addMetaNote(n: MetaLog.Note) = notes.addMetaNote(MetaNoteRow(n.messageId, n.date, n.op.wire, encodeIds(n.ids), n.album))
    suspend fun removeMetaNotes(ids: Collection<Long>) = ids.chunked(500).forEach { notes.removeMetaNotes(it) }

    // Changes waiting to be sent (iOS `trash_outbox`, `meta_outbox`)

    /**
     * Changes an item's Recently Deleted state and queues its note in one transaction (iOS `changeTrashState`).
     * Written apart, a scan between the two sees a change with no note waiting and follows the channel, which undid
     * the user's delete or recover. [chatId] null: no note (the demo). A change that didn't take queues nothing.
     */
    suspend fun changeTrashState(id: String, op: TrashLog.Op, chatId: Long?, change: (LibraryItem) -> LibraryItem): LibraryItem? =
        db.withTransaction {
            val item = dao.item(id)?.let(::toItem) ?: return@withTransaction null
            val updated = change(item)
            dao.upsert(listOf(toRow(updated)))
            if (chatId != null && (item.status == ItemStatus.Trashed) != (updated.status == ItemStatus.Trashed)) {
                notes.queueTrash(listOf(TrashOutboxRow(id, chatId, op.wire)))
            }
            updated
        }

    /** Queues a change to send. One row per item: only its latest change matters. */
    suspend fun queueTrashChange(op: TrashLog.Op, ids: Collection<String>, chatId: Long) =
        db.withTransaction { ids.chunked(500).forEach { c -> notes.queueTrash(c.map { TrashOutboxRow(it, chatId, op.wire) }) } }

    /** Changes waiting to be sent to this library, by action. */
    suspend fun queuedTrashChanges(chatId: Long): Map<TrashLog.Op, List<String>> =
        notes.trashOutbox(chatId).mapNotNull { r -> TrashLog.Op.of(r.op)?.let { it to r.itemId } }.groupBy({ it.first }, { it.second })

    /** Clears sent changes. Only rows still holding [op]: the user may have changed their mind during the send. */
    suspend fun clearTrashChanges(op: TrashLog.Op, ids: Collection<String>) = ids.chunked(500).forEach { notes.clearTrash(it, op.wire) }

    /** iOS test builds queued `gone`; nothing would ever clear those. */
    suspend fun dropRetiredTrashChanges() = notes.dropRetiredTrash()

    /**
     * Sets [key] to [value] on the items and queues the change in one transaction (iOS `changeMeta`). Queued even when
     * the index already agrees: another device may still have the old value. [chatId] null: this phone only.
     */
    suspend fun changeMeta(ids: Collection<String>, key: MetaLog.Key, value: Boolean, chatId: Long?): List<LibraryItem> =
        db.withTransaction {
            val changed = ArrayList<LibraryItem>()
            for (item in items(ids)) {
                val applied = MetaLog.apply(mapOf(key to value), item.favorite, item.locked, item.albums.ifEmpty { null })
                if (applied.changed) {
                    val updated = item.copy(
                        favorite = applied.favorite ?: false,
                        locked = applied.locked ?: false,
                        albums = applied.albums ?: emptyList(),
                    )
                    dao.upsert(listOf(toRow(updated)))
                    changed += updated
                }
            }
            if (chatId != null) ids.chunked(500).forEach { c -> notes.queueMeta(c.map { MetaOutboxRow(it, key.stored, chatId, value) }) }
            changed
        }

    /** Changes waiting to be sent to this library: item → key → value. */
    suspend fun queuedMetaChanges(chatId: Long): Map<String, Map<MetaLog.Key, Boolean>> {
        val result = HashMap<String, MutableMap<MetaLog.Key, Boolean>>()
        for (r in notes.metaOutbox(chatId)) {
            val key = MetaLog.Key.ofStored(r.key) ?: continue
            result.getOrPut(r.itemId) { HashMap() }[key] = r.value
        }
        return result
    }

    /** Clears a sent change. Only rows still holding [value]: the user may have changed their mind during the send. */
    suspend fun clearMetaChange(ids: Collection<String>, key: MetaLog.Key, value: Boolean) =
        ids.chunked(500).forEach { notes.clearMeta(it, key.stored, value) }

    /** The favorite the phone had last time it was checked: item id → value. */
    suspend fun phoneFavorites(): Map<String, Boolean> = notes.phoneFavorites().associate { it.itemId to it.value }

    /** Remembers what the phone has now; null forgets the item. */
    suspend fun setPhoneFavorites(values: Map<String, Boolean?>) = db.withTransaction {
        values.entries.filter { it.value == null }.map { it.key }.chunked(500).forEach { notes.forgetPhoneFavorites(it) }
        notes.setPhoneFavorites(values.mapNotNull { (id, v) -> v?.let { PhoneFavoriteRow(id, it) } })
    }

    suspend fun meta(key: String): String? = notes.meta(key)
    suspend fun setMeta(key: String, value: String?) = if (value == null) notes.removeMeta(key) else notes.setMeta(MetaRow(key, value))

    private companion object {
        const val ALIAS = "alias:"
        const val LARGE_LIBRARY = 10_000
    }

    private fun encodeIds(ids: List<String>) = NoteIds.encode(ids)
    private fun decodeIds(text: String) = NoteIds.decode(text)

    /** Only for a full scan into an index with no phone-linked items yet (Phase C merges instead). */
    suspend fun replaceAll(items: List<LibraryItem>) = dao.replaceAll(items.map(::toRow))

    private fun toRow(i: LibraryItem) = ItemRow(
        id = i.id, localId = i.localId, sha256 = i.sha256, status = i.status.code, createdAt = i.createdAt, kind = i.kind.code,
        filename = i.filename, width = i.width, height = i.height, duration = i.duration, fileSize = i.fileSize,
        favorite = i.favorite, locked = i.locked, hidden = i.hidden, latitude = i.latitude, longitude = i.longitude,
        uploadedAt = i.uploadedAt, verifiedAt = i.verifiedAt, extras = ItemExtras.encode(i),
    )

    private fun toItem(r: ItemRow): LibraryItem {
        val item = LibraryItem(
            id = r.id, localId = r.localId, sha256 = r.sha256, filename = r.filename, kind = ItemKind.of(r.kind),
            createdAt = r.createdAt, latitude = r.latitude, longitude = r.longitude, width = r.width, height = r.height,
            duration = r.duration, fileSize = r.fileSize, status = ItemStatus.of(r.status), favorite = r.favorite,
            locked = r.locked, hidden = r.hidden, uploadedAt = r.uploadedAt, verifiedAt = r.verifiedAt,
        )
        return ItemExtras.apply(item, ItemExtras.decode(r.extras))
    }
}

/** The first value at once, then at most one every [ms]; the latest wins. */
private fun <T> Flow<T>.throttled(ms: Long): Flow<T> = flow {
    var last = 0L
    conflate().collect {
        val wait = last + ms - System.currentTimeMillis()
        if (wait > 0) kotlinx.coroutines.delay(wait)
        last = System.currentTimeMillis()
        emit(it)
    }
}
