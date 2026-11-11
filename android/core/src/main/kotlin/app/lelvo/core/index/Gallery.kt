package app.lelvo.core.index

/**
 * A photo or video on this phone, as the timeline needs it (iOS uses `PHAsset`). [localId] is the MediaStore id;
 * [takenAt] is the capture date and [addedAt] when it came to the phone, both in epoch ms. Files without a capture
 * date (no EXIF date, and Android doesn't let an app set one) have only [addedAt].
 */
data class PhoneAsset(
    val localId: String,
    val takenAt: Long?,
    val isVideo: Boolean,
    val duration: Double? = null,
    val width: Int = 0,
    val height: Int = 0,
    val isFavorite: Boolean = false,
    val filename: String = "",
    val addedAt: Long? = null,
)

/** What a tile's small badge says about its backup (iOS `BackupBadge`, same meanings and words). */
enum class BackupBadge(val label: String, val explanation: String) {
    BackedUp("On phone and in the cloud", "Safe: on this phone and verified in your Telegram library."),
    PhoneOnly("Only on this phone", "Not backed up. It isn't in your backup selection (Settings) or isn't queued yet."),
    CloudOnly("Only in the cloud", "Not on this phone (deleted here or from another device). Opens from Telegram."),
    Waiting("Waiting to upload", "Queued. It uploads on the next backup run."),
    Uploading("Uploading now", "Being uploaded right now."),
    Failed("Backup failed", "The upload didn't go through. Backup → Failed shows why; tap Retry."),
    TooLarge("Too large to back up", "Larger than Telegram allows, so it stays on this phone only."),
}

/** One tile in the unified timeline: a phone photo, a cloud item, or both (iOS `GalleryEntry`). */
data class GalleryEntry(val id: String, val date: Long?, val asset: PhoneAsset?, val item: LibraryItem?) {
    val isVideo: Boolean get() = asset?.isVideo ?: (item?.kind == ItemKind.Video)
    val isLive: Boolean get() = asset == null && item?.kind == ItemKind.LivePhoto
    val duration: Double? get() = asset?.duration ?: item?.duration
    val isCloudOnly: Boolean get() = asset == null

    /** The phone decides for a photo on it; otherwise the Telegram library's favorite. */
    val isFavorite: Boolean get() = asset?.isFavorite ?: (item?.favorite == true)

    val badge: BackupBadge
        get() {
            val item = item ?: return BackupBadge.PhoneOnly
            return when (item.status) {
                ItemStatus.BackedUp -> if (asset == null) BackupBadge.CloudOnly else BackupBadge.BackedUp
                ItemStatus.TooLarge -> BackupBadge.TooLarge
                ItemStatus.Queued -> BackupBadge.Waiting
                ItemStatus.Uploading -> BackupBadge.Uploading
                ItemStatus.Failed -> BackupBadge.Failed
                // Deleted from the cloud: only the phone copy is left.
                ItemStatus.Trashed -> BackupBadge.PhoneOnly
            }
        }
}

/** What a grid shows: everything, or one of the filters (iOS `GalleryFilter`). */
enum class GalleryFilter(val title: String) {
    Videos("Videos"), LivePhotos("Live Photos"), Favorites("Favorites"), CloudOnly("Only in the cloud"), NotBackedUp("Not backed up");

    fun matches(e: GalleryEntry): Boolean = when (this) {
        Videos -> e.isVideo
        LivePhotos -> e.isLive
        Favorites -> e.asset?.isFavorite == true || e.item?.favorite == true
        CloudOnly -> e.isCloudOnly
        NotBackedUp -> e.badge in setOf(BackupBadge.PhoneOnly, BackupBadge.Waiting, BackupBadge.Failed)
    }
}

object Gallery {
    /**
     * Phone photos and cloud items in one newest-first list (iOS `GalleryModel.merge`). Every phone photo is a tile,
     * with its backup item when linked. A cloud item is a tile of its own only when it's backed up, not hidden, and
     * its photo isn't on this phone. [assets] must be newest first by capture date, else date added.
     */
    fun merge(assets: List<PhoneAsset>, items: List<LibraryItem>): List<GalleryEntry> {
        val byLocal = HashMap<String, LibraryItem>()
        for (item in items) {
            val id = item.localId ?: continue
            // A backed-up item wins over a queued duplicate of the same photo.
            val have = byLocal[id]
            if (have == null || (have.status != ItemStatus.BackedUp && item.status == ItemStatus.BackedUp)) byLocal[id] = item
        }
        val present = HashSet<String>(assets.size * 2)
        val onPhone = HashSet<String>()
        val local = ArrayList<GalleryEntry>(assets.size)
        var reorder = false
        for (a in assets) {
            present += a.localId
            val item = byLocal[a.localId]
            if (item != null) onPhone += item.id
            // No capture date on the phone: the backup's, when it's the same photo (saved back from the cloud), else
            // the day it was added, so it still has a place.
            val date = a.takenAt ?: item?.createdAt ?: a.addedAt
            if (date != a.takenAt) reorder = true
            local += GalleryEntry(a.localId, date, a, item)
        }
        if (reorder) local.sortByDescending { it.date ?: Long.MIN_VALUE }
        val cloud = items
            .filter { it.status == ItemStatus.BackedUp && !it.hidden && it.id !in onPhone && (it.localId == null || it.localId !in present) }
            .sortedWith(compareBy<LibraryItem> { it.createdAt == null }.thenByDescending { it.createdAt ?: 0 }.thenBy { it.id })
            .map { GalleryEntry("cloud-${it.id}", it.createdAt, null, it) }
        val out = ArrayList<GalleryEntry>(local.size + cloud.size)
        var i = 0
        var j = 0
        while (i < local.size || j < cloud.size) {
            if (j >= cloud.size || (i < local.size && (local[i].date ?: Long.MIN_VALUE) >= (cloud[j].date ?: Long.MIN_VALUE))) out += local[i++]
            else out += cloud[j++]
        }
        return out
    }
}
