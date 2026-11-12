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
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map

/** The local index (iOS `LibraryStore`): every call runs off the main thread. */
class LibraryStore(private val db: IndexDatabase) {
    private val dao = db.items()
    private val notes = db.notes()

    /** Every item, updated on each change. Rows are decoded off the main thread. */
    fun items(): Flow<List<LibraryItem>> = dao.all().map { rows -> rows.map(::toItem) }.flowOn(Dispatchers.Default)

    suspend fun item(id: String): LibraryItem? = dao.item(id)?.let(::toItem)
    suspend fun upsert(items: List<LibraryItem>) = dao.upsert(items.map(::toRow))
    suspend fun backedUpCount(): Int = dao.backedUpCount()
    suspend fun allItems(): List<LibraryItem> = dao.allNow().map(::toItem)

    /** Chunked: Android 10's SQLite allows 999 values in one query. */
    suspend fun items(ids: Collection<String>): List<LibraryItem> = ids.chunked(500).flatMap { dao.items(it) }.map(::toItem)

    suspend fun delete(id: String) = dao.delete(id)

    suspend fun items(status: ItemStatus): List<LibraryItem> = dao.withStatus(status.code).map(::toItem)
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

    /** Everything in the index: items, notes, meta and the off-backup list (a new library or a reset). */
    suspend fun deleteAll() = db.withTransaction {
        dao.deleteAll(); notes.clearTrashNotes(); notes.clearMetaNotes(); notes.clearMeta(); notes.clearNoBackup()
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

    suspend fun meta(key: String): String? = notes.meta(key)
    suspend fun setMeta(key: String, value: String?) = if (value == null) notes.removeMeta(key) else notes.setMeta(MetaRow(key, value))

    private companion object { const val ALIAS = "alias:" }

    private fun encodeIds(ids: List<String>) = NoteIds.encode(ids)
    private fun decodeIds(text: String) = NoteIds.decode(text)

    /** Only for a full scan into an index with no phone-linked items yet (Phase C merges instead). */
    suspend fun replaceAll(items: List<LibraryItem>) = dao.replaceAll(items.map(::toRow))

    private fun toRow(i: LibraryItem) = ItemRow(
        id = i.id, localId = i.localId, sha256 = i.sha256, status = i.status.code, createdAt = i.createdAt, kind = i.kind.code,
        filename = i.filename, width = i.width, height = i.height, duration = i.duration, fileSize = i.fileSize,
        favorite = i.favorite, hidden = i.hidden, latitude = i.latitude, longitude = i.longitude, uploadedAt = i.uploadedAt,
        verifiedAt = i.verifiedAt, extras = ItemExtras.encode(i),
    )

    private fun toItem(r: ItemRow): LibraryItem {
        val item = LibraryItem(
            id = r.id, localId = r.localId, sha256 = r.sha256, filename = r.filename, kind = ItemKind.of(r.kind),
            createdAt = r.createdAt, latitude = r.latitude, longitude = r.longitude, width = r.width, height = r.height,
            duration = r.duration, fileSize = r.fileSize, status = ItemStatus.of(r.status), favorite = r.favorite,
            hidden = r.hidden, uploadedAt = r.uploadedAt, verifiedAt = r.verifiedAt,
        )
        return ItemExtras.apply(item, ItemExtras.decode(r.extras))
    }
}
