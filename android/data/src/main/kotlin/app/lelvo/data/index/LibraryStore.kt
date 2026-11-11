package app.lelvo.data.index

import app.lelvo.core.index.ItemExtras
import app.lelvo.core.index.ItemKind
import app.lelvo.core.index.ItemStatus
import app.lelvo.core.index.LibraryItem
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map

/** The local index (iOS `LibraryStore`): every call runs off the main thread. */
class LibraryStore(private val db: IndexDatabase) {
    private val dao = db.items()

    /** Every item, updated on each change. Rows are decoded off the main thread. */
    fun items(): Flow<List<LibraryItem>> = dao.all().map { rows -> rows.map(::toItem) }.flowOn(Dispatchers.Default)

    suspend fun item(id: String): LibraryItem? = dao.item(id)?.let(::toItem)
    suspend fun upsert(items: List<LibraryItem>) = dao.upsert(items.map(::toRow))
    suspend fun backedUpCount(): Int = dao.backedUpCount()
    suspend fun deleteAll() = dao.deleteAll()

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
