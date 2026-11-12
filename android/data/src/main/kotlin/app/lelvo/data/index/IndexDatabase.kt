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
    val hidden: Boolean,
    val latitude: Double?,
    val longitude: Double?,
    @androidx.room.ColumnInfo(name = "uploaded_at") val uploadedAt: Long?,
    @androidx.room.ColumnInfo(name = "verified_at") val verifiedAt: Long?,
    val extras: String,
)

@Dao
interface ItemDao {
    @Upsert suspend fun upsert(rows: List<ItemRow>)
    @Query("SELECT * FROM items") fun all(): Flow<List<ItemRow>>
    @Query("SELECT * FROM items WHERE id = :id") suspend fun item(id: String): ItemRow?
    @Query("SELECT COUNT(*) FROM items WHERE status = 'backedUp'") suspend fun backedUpCount(): Int
    @Query("DELETE FROM items") suspend fun deleteAll()
    @Query("SELECT * FROM items") suspend fun allNow(): List<ItemRow>
    @Query("SELECT * FROM items WHERE id IN (:ids)") suspend fun items(ids: List<String>): List<ItemRow>
    @Query("DELETE FROM items WHERE id = :id") suspend fun delete(id: String)
    @Query("SELECT * FROM items WHERE status = :status") suspend fun withStatus(status: String): List<ItemRow>
    @Query("SELECT * FROM items WHERE sha256 = :sha256") suspend fun withHash(sha256: String): List<ItemRow>
    @Query("SELECT * FROM items WHERE local_id = :localId LIMIT 1") suspend fun withLocalId(localId: String): ItemRow?
    @Query("SELECT local_id FROM items WHERE local_id IS NOT NULL") suspend fun localIds(): List<String>
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

@Dao
interface NotesDao {
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
}

@Database(
    entities = [ItemRow::class, TrashNoteRow::class, MetaNoteRow::class, MetaRow::class, NoBackupRow::class],
    version = 2,
    exportSchema = true,
    autoMigrations = [AutoMigration(from = 1, to = 2)],
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
