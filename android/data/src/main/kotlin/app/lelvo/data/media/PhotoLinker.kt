package app.lelvo.data.media

import app.lelvo.core.index.ItemStatus
import app.lelvo.core.index.RestoreLinker
import app.lelvo.core.support.AppLog
import app.lelvo.data.index.LibraryStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * Links restored cloud items to the photos still on this phone (iOS `relinkRestoredItems`), so they show as backed
 * up rather than "on the phone only", and aren't uploaded a second time. Reads no file.
 */
class PhotoLinker(private val store: LibraryStore, private val photos: PhotoAccess) {
    private val gate = Mutex()

    /** Returns how many items were linked. Sign-in, launch and scans can each ask; one pass at a time is enough. */
    suspend fun relink(): Int = withContext(Dispatchers.IO) {
        gate.withLock {
            val status = photos.status()
            if (status != PhotoAccess.Status.Full && status != PhotoAccess.Status.Partial) return@withLock 0
            // SQL picks the few rows this needs; it runs on every launch and every backup run.
            val unlinked = store.unlinkedBackedUp()
            if (unlinked.isEmpty()) return@withLock 0
            val linked = store.linkedLocalIds()
            val started = System.currentTimeMillis()
            val assets = photos.assetKeys().filter { it.localId !in linked }
            val links = RestoreLinker.match(unlinked, assets)
            AppLog.info("Relink: ${assets.size} candidate photos, in ${System.currentTimeMillis() - started} ms")
            if (links.isEmpty()) return@withLock 0
            // Waiting to upload a photo that turns out to be backed up already: that queue entry goes.
            val linkedAssets = links.values.toHashSet()
            val duplicates = store.itemsForPhone(linkedAssets).filter { it.status != ItemStatus.BackedUp && it.status != ItemStatus.Uploading }
            duplicates.forEach { store.delete(it.id) }
            store.upsert(unlinked.mapNotNull { item -> links[item.id]?.let { item.copy(localId = it) } })
            AppLog.info("Relinked ${links.size} of ${unlinked.size} restored items to photos on this phone (${duplicates.size} queued duplicates removed)")
            links.size
        }
    }
}
