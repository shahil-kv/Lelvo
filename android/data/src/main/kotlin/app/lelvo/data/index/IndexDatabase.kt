package app.lelvo.data.index

import android.content.Context
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

    /** One transaction, so the timeline never sees the index half replaced. */
    @Transaction suspend fun replaceAll(rows: List<ItemRow>) {
        deleteAll()
        upsert(rows)
    }
}

@Database(entities = [ItemRow::class], version = 1, exportSchema = true)
abstract class IndexDatabase : RoomDatabase() {
    abstract fun items(): ItemDao

    companion object {
        fun open(context: Context): IndexDatabase =
            // No destructive fallback: a schema change needs a migration, written on purpose.
            Room.databaseBuilder(context, IndexDatabase::class.java, "index.db").build()
    }
}
