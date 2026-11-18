package app.lelvo.data.index

import android.content.Context
import androidx.room.AutoMigration
import androidx.room.ColumnInfo
import androidx.room.Dao
import androidx.room.Database
import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.Transaction
import androidx.room.Upsert
import kotlinx.coroutines.flow.Flow

/**
 * One row per item, like the iOS `items` table: the columns the app queries, the rest (parts, albums) as JSON.
 * A cache of the channel: losing it costs a rescan, never a photo.
 */
@Entity(tableName = "items", indices = [Index("local_id"), Index("sha256"), Index("status"), Index("created_at")])
data class ItemRow(
    @PrimaryKey val id: String,
    @androidx.room.ColumnInfo(name = "local_id") val localId: String?,
    val sha256: String,
    val status: String,
    @androidx.room.ColumnInfo(name = "created_at") val createdAt: Long?,
    val kind: String,
    val filename: String,
    val width: Int,
    val height: Int,
    val duration: Double?,
    @androidx.room.ColumnInfo(name = "file_size") val fileSize: Long,
    val favorite: Boolean,
    /** Locked Folder (#129). Default false for AutoMigration 3→4. */
    @ColumnInfo(defaultValue = "0") val locked: Boolean = false,
    val hidden: Boolean,
    val latitude: Double?,
    val longitude: Double?,
    @androidx.room.ColumnInfo(name = "uploaded_at") val uploadedAt: Long?,
    @androidx.room.ColumnInfo(name = "verified_at") val verifiedAt: Long?,
    val extras: String,
)

/** A queued row's id and the phone photo it belongs to. No extras: tens of thousands of these stay small. */
data class IdAndLocal(val id: String, @ColumnInfo(name = "local_id") val localId: String)

/** A backed-up row, enough to say whether its photo is still on this phone and where it sits in time. */
data class BackedUpRef(
    val id: String,
    @ColumnInfo(name = "local_id") val localId: String?,
    val hidden: Boolean,
    @ColumnInfo(name = "created_at") val createdAt: Long?,
)

/** A backed-up row linked to a phone photo, with its favorite: enough to match favorites with the phone. */
data class FavoriteRef(val id: String, @ColumnInfo(name = "local_id") val localId: String, val favorite: Boolean)

/** A photo's place in the cloud index, without the rest of the row. */
data class LatLon(val latitude: Double, val longitude: Double)

@Dao
interface ItemDao {
    @Upsert suspend fun upsert(rows: List<ItemRow>)
    @Query("SELECT * FROM items") fun all(): Flow<List<ItemRow>>
    @Query("SELECT * FROM items WHERE id = :id") suspend fun item(id: String): ItemRow?
    @Query("SELECT COUNT(*) FROM items WHERE status = 'backedUp'") suspend fun backedUpCount(): Int
    @Query("DELETE FROM items") suspend fun deleteAll()
    @Transaction @Query("SELECT * FROM items") suspend fun allNow(): List<ItemRow>
    @Transaction @Query("SELECT * FROM items WHERE id IN (:ids)") suspend fun items(ids: List<String>): List<ItemRow>
    @Query("SELECT * FROM items WHERE local_id IN (:localIds)") suspend fun withLocalIds(localIds: List<String>): List<ItemRow>
    @Query("DELETE FROM items WHERE id = :id") suspend fun delete(id: String)
    @Transaction @Query("SELECT * FROM items WHERE status = :status") suspend fun withStatus(status: String): List<ItemRow>
    // Light reads for work that runs on its own (launch, every backup, every sync). A list of whole rows here is
    // tens of megabytes on a large library, and a cursor that long can throw while a backup writes to the table.
    @Query("SELECT id FROM items") suspend fun ids(): List<String>
    @Query("SELECT id FROM items WHERE locked = 1") suspend fun lockedIds(): List<String>
    @Query("SELECT local_id FROM items WHERE locked = 1 AND local_id IS NOT NULL") suspend fun lockedLocalIds(): List<String>
    @Query("SELECT * FROM items WHERE locked = 1 AND status IN ('backedUp', 'trashed')") suspend fun lockedInCloud(): List<ItemRow>
    @Query("SELECT * FROM items WHERE status = 'backedUp' AND local_id IS NULL") suspend fun unlinkedBackedUp(): List<ItemRow>
    @Query("SELECT local_id FROM items WHERE status = 'backedUp' AND local_id IS NOT NULL") suspend fun linkedLocalIds(): List<String>
    @Query("SELECT id, local_id, favorite FROM items WHERE status = 'backedUp' AND local_id IS NOT NULL")
    suspend fun favoriteRefs(): List<FavoriteRef>
    @Query("SELECT COUNT(*) FROM items WHERE instr(extras, CAST(x'2270223A7B22' AS TEXT)) > 0") suspend fun withPartsCount(): Int
    @Query("SELECT * FROM items WHERE status = 'backedUp' AND local_id IS NOT NULL AND id > :after ORDER BY id LIMIT :limit")
    suspend fun backedUpOnPhonePage(after: String, limit: Int): List<ItemRow>
    @Query("SELECT COUNT(*) FROM items") suspend fun countAll(): Int
    @Query("SELECT COUNT(*) FROM items WHERE status = 'trashed'") suspend fun trashedCount(): Int
    @Query("SELECT COUNT(*) FROM items WHERE status = 'failed'") suspend fun failedCount(): Int
    // The extras markers [app.lelvo.core.backup.UploadOrder] looks for, written as hex so the SQL parser never sees
    // a quote inside a quote: `"p":{"` parts, `"res"` a resume point, `"ch":1` chosen.
    /** Failed rows a retry can send again: a photo is still on this phone, or nothing of it reached the channel. */
    @Query("SELECT COUNT(*) FROM items WHERE status = 'failed' AND (local_id IS NOT NULL OR instr(extras, CAST(x'2270223A7B22' AS TEXT)) = 0)")
    suspend fun retryableFailedCount(): Int
    /** Queued or uploading, excluding a cloud fragment with no photo on this phone. */
    @Query("SELECT COUNT(*) FROM items WHERE status IN ('queued', 'uploading') AND NOT (local_id IS NULL AND instr(extras, CAST(x'2270223A7B22' AS TEXT)) > 0)")
    suspend fun uploadableCount(): Int
    @Query("SELECT COUNT(*) FROM items WHERE status IN ('queued', 'uploading') AND local_id IS NULL AND instr(extras, CAST(x'2270223A7B22' AS TEXT)) > 0")
    suspend fun strandedCount(): Int
    @Query("SELECT COUNT(*) FROM items WHERE status IN ('queued', 'uploading') AND instr(extras, CAST(x'226368223A31' AS TEXT)) > 0 AND NOT (local_id IS NULL AND instr(extras, CAST(x'2270223A7B22' AS TEXT)) > 0)")
    suspend fun chosenUploadableCount(): Int
    @Query("SELECT COUNT(*) FROM items WHERE status = 'queued' AND local_id IS NOT NULL")
    suspend fun queuedWithPhoneCount(): Int
    @Query("SELECT COUNT(*) FROM items WHERE status = 'queued' AND local_id IS NOT NULL AND instr(extras, CAST(x'226368223A31' AS TEXT)) > 0")
    suspend fun chosenQueuedCount(): Int
    /**
     * Ids still waiting, in upload order: a half-done item, then photos, then videos, newest first. The rank matches
     * [app.lelvo.core.backup.UploadOrder]. Null dates sort last, as they do in memory.
     */
    @Query("SELECT id FROM items WHERE status = 'queued' AND local_id IS NOT NULL ORDER BY CASE WHEN instr(extras, CAST(x'2272657322' AS TEXT)) > 0 OR instr(extras, CAST(x'2270223A7B22' AS TEXT)) > 0 THEN 0 WHEN kind = 'video' THEN 2 ELSE 1 END, created_at IS NULL, created_at DESC")
    suspend fun queuedIdsInOrder(): List<String>
    @Query("SELECT id FROM items WHERE status = 'queued' AND local_id IS NOT NULL AND instr(extras, CAST(x'226368223A31' AS TEXT)) > 0 ORDER BY CASE WHEN instr(extras, CAST(x'2272657322' AS TEXT)) > 0 OR instr(extras, CAST(x'2270223A7B22' AS TEXT)) > 0 THEN 0 WHEN kind = 'video' THEN 2 ELSE 1 END, created_at IS NULL, created_at DESC")
    suspend fun chosenQueuedIdsInOrder(): List<String>
    @Query("SELECT id, local_id FROM items WHERE status = 'queued' AND local_id IS NOT NULL")
    suspend fun queuedLocalIds(): List<IdAndLocal>
    @Query("SELECT * FROM items WHERE status = 'queued' AND local_id IS NULL")
    suspend fun queuedWithoutPhone(): List<ItemRow>
    @Query("SELECT local_id FROM items WHERE status = 'trashed' AND local_id IS NOT NULL")
    suspend fun trashedLocalIds(): List<String>
    @Query("SELECT id, local_id, hidden, created_at FROM items WHERE status = 'backedUp'")
    suspend fun backedUpRefs(): List<BackedUpRef>
    @Query("SELECT latitude, longitude FROM items WHERE latitude IS NOT NULL AND longitude IS NOT NULL")
    suspend fun coordinates(): List<LatLon>
    @Query("SELECT * FROM items WHERE sha256 = :sha256") suspend fun withHash(sha256: String): List<ItemRow>
    @Query("SELECT * FROM items WHERE local_id = :localId LIMIT 1") suspend fun withLocalId(localId: String): ItemRow?
    @Transaction @Query("SELECT local_id FROM items WHERE local_id IS NOT NULL") suspend fun localIds(): List<String>
    @Query("DELETE FROM items WHERE id = :id AND status = 'queued'") suspend fun deleteIfQueued(id: String): Int

    /** One transaction, so the timeline never sees the index half replaced. */
    @Transaction suspend fun replaceAll(rows: List<ItemRow>) {
        deleteAll()
        upsert(rows)
    }
}

/** A Recently Deleted note read from the channel (iOS `trash_notes`). `ids` is a JSON array. */
@Entity(tableName = "trash_notes")
data class TrashNoteRow(@PrimaryKey @ColumnInfo(name = "message_id") val messageId: Long, val date: Long, val op: String, val ids: String)

/** A favorites and albums note read from the channel (iOS `meta_notes`). */
@Entity(tableName = "meta_notes")
data class MetaNoteRow(
    @PrimaryKey @ColumnInfo(name = "message_id") val messageId: Long,
    val date: Long,
    val op: String,
    val ids: String,
    val album: String?,
)

/** Small values kept with the index, so they go when it does (iOS `meta`). */
@Entity(tableName = "meta")
data class MetaRow(@PrimaryKey val key: String, val value: String)

/** Photos on this phone that must not be backed up again: deleted for good from the library (iOS `no_backup`). */
@Entity(tableName = "no_backup")
data class NoBackupRow(@PrimaryKey val key: String)

/**
 * A phone photo set aside because it can't be read (a damaged file, or one gone from the cloud copy of the gallery): backing
 * up skips it until the photo changes, so Retry doesn't try the same unreadable file again and again (iOS `ignored_assets`).
 * [modified] is the photo's modification time in whole seconds when it was set aside, or empty when unknown.
 */
@Entity(tableName = "ignored_assets")
data class IgnoredAssetRow(
    @PrimaryKey @ColumnInfo(name = "local_id") val localId: String,
    val reason: String,
    val modified: String,
    @ColumnInfo(name = "ignored_at") val ignoredAt: Long,
)

/**
 * A Recently Deleted change waiting to be sent (iOS `trash_outbox`): one row per item, its latest change. Per library,
 * so a switch can't send it to the wrong channel.
 */
@Entity(tableName = "trash_outbox")
data class TrashOutboxRow(
    @PrimaryKey @ColumnInfo(name = "item_id") val itemId: String,
    @ColumnInfo(name = "chat_id") val chatId: Long,
    val op: String,
)

/** A favorite or album change waiting to be sent (iOS `meta_outbox`): one row per item and key. */
@Entity(tableName = "meta_outbox", primaryKeys = ["item_id", "key"])
data class MetaOutboxRow(
    @ColumnInfo(name = "item_id") val itemId: String,
    val key: String,
    @ColumnInfo(name = "chat_id") val chatId: Long,
    val value: Boolean,
)

/** The favorite the phone's gallery had last time it was checked (iOS `photos_favorite`, #99). */
@Entity(tableName = "phone_favorite")
data class PhoneFavoriteRow(@PrimaryKey @ColumnInfo(name = "item_id") val itemId: String, val value: Boolean)

@Dao
interface NotesDao {
    @Upsert suspend fun queueTrash(rows: List<TrashOutboxRow>)
    @Query("SELECT * FROM trash_outbox WHERE chat_id = :chatId ORDER BY item_id") suspend fun trashOutbox(chatId: Long): List<TrashOutboxRow>
    @Query("DELETE FROM trash_outbox WHERE item_id IN (:ids) AND op = :op") suspend fun clearTrash(ids: List<String>, op: String)
    @Query("DELETE FROM trash_outbox WHERE op = 'gone'") suspend fun dropRetiredTrash()
    @Upsert suspend fun queueMeta(rows: List<MetaOutboxRow>)
    @Query("SELECT * FROM meta_outbox WHERE chat_id = :chatId") suspend fun metaOutbox(chatId: Long): List<MetaOutboxRow>
    @Query("DELETE FROM meta_outbox WHERE item_id IN (:ids) AND `key` = :key AND value = :value")
    suspend fun clearMeta(ids: List<String>, key: String, value: Boolean)
    @Query("SELECT * FROM phone_favorite") suspend fun phoneFavorites(): List<PhoneFavoriteRow>
    @Upsert suspend fun setPhoneFavorites(rows: List<PhoneFavoriteRow>)
    @Query("DELETE FROM phone_favorite WHERE item_id IN (:ids)") suspend fun forgetPhoneFavorites(ids: List<String>)
    @Query("DELETE FROM trash_outbox") suspend fun clearTrashOutbox()
    @Query("DELETE FROM meta_outbox") suspend fun clearMetaOutbox()
    @Query("DELETE FROM phone_favorite") suspend fun clearPhoneFavorites()

    @Query("SELECT * FROM trash_notes ORDER BY message_id") suspend fun trashNotes(): List<TrashNoteRow>
    @Upsert suspend fun addTrashNote(row: TrashNoteRow)
    @Query("DELETE FROM trash_notes WHERE message_id IN (:ids)") suspend fun removeTrashNotes(ids: List<Long>)
    @Query("SELECT * FROM meta_notes ORDER BY message_id") suspend fun metaNotes(): List<MetaNoteRow>
    @Upsert suspend fun addMetaNote(row: MetaNoteRow)
    @Query("DELETE FROM meta_notes WHERE message_id IN (:ids)") suspend fun removeMetaNotes(ids: List<Long>)
    @Query("SELECT value FROM meta WHERE key = :key") suspend fun meta(key: String): String?
    @Upsert suspend fun setMeta(row: MetaRow)
    @Query("DELETE FROM meta WHERE key = :key") suspend fun removeMeta(key: String)
    @Upsert suspend fun addNoBackup(rows: List<NoBackupRow>)
    @Query("SELECT COUNT(*) FROM no_backup WHERE key = :key") suspend fun isNoBackup(key: String): Int
    @Query("SELECT `key` FROM no_backup") suspend fun noBackupKeys(): List<String>
    @Query("DELETE FROM no_backup WHERE `key` = :key") suspend fun removeNoBackup(key: String)
    @Query("SELECT `key` FROM meta WHERE `key` LIKE 'alias:%'") suspend fun aliasKeys(): List<String>
    @Query("SELECT * FROM meta WHERE `key` LIKE 'alias:%'") suspend fun aliasRows(): List<MetaRow>
    @Query("DELETE FROM trash_notes") suspend fun clearTrashNotes()
    @Query("DELETE FROM meta_notes") suspend fun clearMetaNotes()
    @Query("DELETE FROM meta") suspend fun clearMeta()
    @Query("DELETE FROM no_backup") suspend fun clearNoBackup()
    @Upsert suspend fun ignoreAsset(row: IgnoredAssetRow)
    @Query("SELECT * FROM ignored_assets ORDER BY ignored_at DESC") suspend fun ignoredAssets(): List<IgnoredAssetRow>
    @Query("SELECT count(*) FROM ignored_assets") suspend fun ignoredAssetCount(): Int
    @Query("SELECT modified FROM ignored_assets WHERE local_id = :localId") suspend fun ignoredModified(localId: String): String?
    @Query("DELETE FROM ignored_assets WHERE local_id = :localId") suspend fun unignoreAsset(localId: String)
    @Query("DELETE FROM ignored_assets") suspend fun unignoreAllAssets()
}

@Database(
    entities = [
        ItemRow::class, TrashNoteRow::class, MetaNoteRow::class, MetaRow::class, NoBackupRow::class,
        TrashOutboxRow::class, MetaOutboxRow::class, PhoneFavoriteRow::class, IgnoredAssetRow::class,
    ],
    version = 5,
    exportSchema = true,
    // 2 → 3: the outboxes and the phone's last-seen favorites (Phase L), new tables only.
    // 3 → 4: Locked Folder flag on items (#129).
    // 4 → 5: photos set aside as unreadable, a new table only (`ignored_assets`).
    autoMigrations = [
        AutoMigration(from = 1, to = 2),
        AutoMigration(from = 2, to = 3),
        AutoMigration(from = 3, to = 4),
        AutoMigration(from = 4, to = 5),
    ],
)
abstract class IndexDatabase : RoomDatabase() {
    abstract fun items(): ItemDao
    abstract fun notes(): NotesDao

    companion object {
        fun open(context: Context): IndexDatabase =
            // No destructive fallback: a schema change needs a migration, written on purpose.
            Room.databaseBuilder(context, IndexDatabase::class.java, "index.db").build()
    }
}
