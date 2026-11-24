package app.lelvo.android.debug

import app.lelvo.core.index.ItemKind
import app.lelvo.core.index.ItemStatus
import app.lelvo.core.index.LibraryItem
import app.lelvo.core.index.RemoteFile
import app.lelvo.core.support.AppLog
import app.lelvo.data.index.LibraryStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Debug only: replaces the local index with synthetic items so grid scroll can be measured without a real 40k
 * MediaStore library (iOS `ScrollLibrarySeed`). Demo mode only: wiping a real index would lose changes waiting to be sent.
 */
object ScrollLibrarySeed {
    suspend fun load(store: LibraryStore, count: Int, albums: Boolean = true, demoActive: Boolean): Int = withContext(Dispatchers.IO) {
        // `deleteAll` also drops changes waiting to be sent and the backed-up links: never on a real library.
        check(demoActive) { "The scroll library only loads in demo mode" }
        val now = System.currentTimeMillis()
        val items = (0 until count).map { i ->
            val trip = (200 until 240).contains(i % 1000)
            val jitter = (i % 13) * 0.002
            LibraryItem(
                id = "scroll-%06d".format(i),
                localId = null,
                sha256 = "%064d".format(i),
                filename = "IMG_%d.HEIC".format(1000 + i),
                kind = if (i % 7 == 0) ItemKind.Video else ItemKind.Photo,
                createdAt = now - i * 9_000_000L,
                latitude = (if (trip) 15.49 else 9.93) + jitter,
                longitude = (if (trip) 73.82 else 76.26) + jitter,
                duration = if (i % 7 == 0) (5 + i % 90).toDouble() else null,
                fileSize = 2_000_000L,
                status = ItemStatus.BackedUp,
                favorite = albums && i % 11 == 0,
                albums = if (albums) listOf("Family ${i % 5 + 1}") else emptyList(),
                parts = mapOf(
                    "o" to listOf(RemoteFile(i + 1L, "demo", "demo$i", 2_000_000L)),
                ),
                expectedParts = mapOf("o" to 1),
            )
        }
        store.deleteAll()
        // Room handles large batches; chunk to keep peak memory down.
        items.chunked(2_000).forEach { store.upsert(it) }
        AppLog.info("Scroll library: loaded $count synthetic items")
        count
    }
}
