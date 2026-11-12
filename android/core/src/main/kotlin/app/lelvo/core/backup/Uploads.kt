package app.lelvo.core.backup

import app.lelvo.core.crypto.FileCrypto
import app.lelvo.core.format.PartLayout
import app.lelvo.core.index.ItemKind
import app.lelvo.core.index.ItemStatus
import app.lelvo.core.index.LibraryItem

/**
 * Keeps every upload within Telegram's limit of two at once, notes included (iOS `UploadSlots`). A waiting note takes
 * the next free slot, so a long backup can't hold it back for hours. Not thread-safe: the engine holds a lock.
 */
class UploadSlots(val limit: Int) {
    private var used = 0
    private var noteWaiting = false

    fun acquireForLane(): Boolean {
        if (used >= limit || noteWaiting) return false
        used++
        return true
    }

    /** Call again until it returns true: until then, the note counts as waiting. */
    fun acquireForNote(): Boolean {
        if (used >= limit) { noteWaiting = true; return false }
        noteWaiting = false
        used++
        return true
    }

    /** The note gave up (cancelled). Without this the lanes would wait for it for ever. */
    fun stopWaitingForNote() { noteWaiting = false }

    fun release() { used = maxOf(0, used - 1) }
}

/**
 * The order a run uploads in (iOS `UploadOrder`): a half-done upload first (some parts already in the channel), then
 * photos, then videos, which can take many minutes each on an account Telegram slows down. Newest first in each group.
 */
object UploadOrder {
    fun sorted(items: List<LibraryItem>): List<LibraryItem> =
        items.sortedWith(compareBy<LibraryItem> { group(it) }.thenByDescending { it.createdAt ?: Long.MIN_VALUE })

    private fun group(item: LibraryItem): Int = when {
        item.hasCloudParts || item.uploadResume.isNotEmpty() -> 0
        item.kind == ItemKind.Video -> 2
        else -> 1
    }
}

/**
 * Tells a slow upload from a stuck one (iOS `UploadStall`). TDLib reports every piece it uploads; when those reports
 * stop for [timeoutMs], the send is waiting on a connection that won't come back by itself (TDLib never fails it). A
 * slow upload, including Telegram's speed limit for accounts without Premium, still moves and is never called stuck.
 */
class UploadStall(startedAt: Long, val timeoutMs: Long = DEFAULT_TIMEOUT_MS) {
    var sent: Long = -1
        private set
    var movedAt: Long = startedAt
        private set
    private var checkedAt: Long? = null

    /** Only new bytes count as moving: TDLib repeats a file's state when other fields change. */
    fun record(sent: Long, now: Long) {
        if (sent == this.sent) return
        this.sent = sent
        movedAt = now
    }

    fun restart(now: Long) { movedAt = now }

    fun isStalled(now: Long): Boolean = now - movedAt >= timeoutMs

    /**
     * The watchdog's periodic look. A gap of more than [SUSPEND_GAP_MS] since the last look means the process was
     * frozen (Doze, cached app): TDLib was frozen too, so that time doesn't count against the upload.
     */
    fun check(now: Long): Boolean {
        checkedAt?.let { if (now - it > SUSPEND_GAP_MS) movedAt = now }
        checkedAt = now
        return isStalled(now)
    }

    companion object {
        const val DEFAULT_TIMEOUT_MS = 180_000L
        const val SUSPEND_GAP_MS = 30_000L
    }
}

/** Upload speed over the last few seconds, for a "time left" estimate (iOS `TransferRate`). */
class TransferRate {
    private val samples = ArrayDeque<Pair<Long, Long>>()

    /** Bytes sent so far for the current file. Going backwards means a new file (or a retry): start over. */
    fun record(bytes: Long, now: Long) {
        samples.lastOrNull()?.let { if (bytes < it.second) samples.clear() }
        samples.addLast(now to bytes)
        while (samples.isNotEmpty() && now - samples.first().first > WINDOW_MS) samples.removeFirst()
    }

    val bytesPerSecond: Double?
        get() {
            val first = samples.firstOrNull() ?: return null
            val last = samples.last()
            val span = (last.first - first.first) / 1000.0
            if (span < MINIMUM_SPAN_MS / 1000.0) return null
            return (last.second - first.second) / span
        }

    fun secondsLeft(total: Long): Int? {
        val rate = bytesPerSecond ?: return null
        val sent = samples.lastOrNull()?.second ?: return null
        if (rate <= 0 || total <= sent) return null
        return kotlin.math.ceil((total - sent) / rate).toInt()
    }

    companion object {
        const val WINDOW_MS = 20_000L
        const val MINIMUM_SPAN_MS = 3_000L
    }
}

/** What the Backup tab says is left to do, in one place (iOS `BackupCounts`). */
data class BackupCounts(val activeQueue: Int = 0, val notQueued: Int = 0, val failed: Int = 0, val retryable: Int = 0) {
    /** Everything "Back up now" would upload. */
    val left: Int get() = activeQueue + notQueued

    fun pending(autoBackup: Boolean): Int = activeQueue + if (autoBackup) notQueued else 0

    companion object {
        /**
         * [queued]: items in the queue, uploading included. [candidates]: phone ids the backup covers. [known]: phone
         * ids the index has in any state. [offBackup]: photos deleted from the backup on purpose.
         */
        fun compute(
            queued: List<LibraryItem>, failed: List<LibraryItem>, candidates: Collection<String>, known: Set<String>,
            offBackup: Set<String>, autoBackup: Boolean,
        ): BackupCounts {
            // Nothing can upload an incomplete item with no photo on this phone: it belongs under Failed.
            val uploadable = queued.filter { !it.isStrandedInCloud }
            val active = if (autoBackup) uploadable.size else uploadable.count { it.chosen }
            return BackupCounts(
                activeQueue = active,
                notQueued = candidates.count { it !in known && it !in offBackup } + (uploadable.size - active),
                failed = failed.size + queued.count { it.isStrandedInCloud },
                retryable = failed.count { !it.isStrandedInCloud },
            )
        }

        /** Photos on this phone the user deleted from the backup, which a backup skips until they choose otherwise. */
        fun removedFromBackup(trashed: List<LibraryItem>, offBackup: Set<String>, known: Set<String>, present: Set<String>): List<String> {
            val inTrash = trashed.mapNotNull { it.localId }.toSet()
            // In the index and not in the trash means it's back in the library, whatever an older mark says.
            val gone = offBackup - known
            return ((inTrash + gone) intersect present).sorted()
        }
    }
}

object Dedupe {
    /**
     * Whether a photo with the same original bytes as [twin] is really the same photo. Android keeps no edit beside
     * the original, so [editHash] is null here unless a future version adds one; kept for parity with iOS, where a
     * cropped copy taken for a duplicate lost its crop.
     */
    fun isSamePhoto(editHash: String?, twin: LibraryItem): Boolean = editHash == null || twin.roleHashes["e"] == editHash

    /**
     * The hash saved when the item was last tried still describes its file, so a retry can skip hashing a big video
     * again: only when the file's modification date and size are unchanged (iOS `canReuseHashes`).
     */
    fun canReuseHashes(item: LibraryItem, modified: Long?, size: Long, pairedSize: Long?): Boolean {
        if (item.sha256.isEmpty() || item.assetModifiedAt == null || item.assetModifiedAt != modified) return false
        if (size != item.fileSize || pairedSize != item.pairedVideoSize) return false
        if (pairedSize != null && item.roleHashes["pv"] == null) return false
        return true
    }
}

object PhotoChangeScan {
    /**
     * Queued items whose photo was deleted from the phone before it was uploaded (iOS `queuedButDeleted`). When none of
     * them is found while the phone has photos, nothing is dropped (a MediaStore hiccup, not 50 deletions). Items with
     * parts in the channel are never dropped: their row is the only local record of those messages.
     */
    fun queuedButDeleted(items: List<LibraryItem>, present: Set<String>, libraryIsEmpty: Boolean): List<LibraryItem> {
        if (present.isEmpty() && !libraryIsEmpty) return emptyList()
        return items.filter {
            it.status == ItemStatus.Queued && !it.hasCloudParts && it.uploadResume.isEmpty() && it.localId != null && it.localId !in present
        }
    }
}

/**
 * When to store a screen copy (role `d`) of a photo (iOS `ScreenCopyPolicy`): a 2048 px JPEG of a few hundred KB opens
 * in well under a second where a 30 MB RAW took seconds. Normal photos of a few MB are skipped.
 */
object ScreenCopyPolicy {
    const val MAX_PIXEL = 2048
    const val JPEG_QUALITY = 82
    const val MINIMUM_BYTES = 3L shl 20
    const val MAXIMUM_SIZE_RATIO = 0.5
    private val raw = setOf("dng", "arw", "cr2", "cr3", "nef", "nrw", "raf", "orf", "rw2", "pef", "srw", "x3f", "3fr", "iiq")

    fun isRaw(filename: String): Boolean = filename.substringAfterLast('.', "").lowercase() in raw

    fun hasScreenCopy(item: LibraryItem): Boolean {
        val have = item.parts["d"]?.size ?: 0
        return have > 0 && have == (item.expectedParts["d"] ?: 1)
    }

    fun shouldMake(item: LibraryItem): Boolean {
        if (item.kind == ItemKind.Video || item.screenCopySkipped || hasScreenCopy(item)) return false
        return item.fileSize >= MINIMUM_BYTES || isRaw(item.filename)
    }

    fun isWorthKeeping(copyBytes: Long, originalBytes: Long): Boolean = originalBytes > 0 && copyBytes <= originalBytes * MAXIMUM_SIZE_RATIO
}

object UploadNames {
    /** File name stored on Telegram for an encrypted part (docs/CLOUD_FORMAT.md §3). Android never writes plain ones. */
    fun encrypted(itemId: String, role: String, part: Int?): String =
        if (part == null) "$itemId.$role.cge" else "$itemId.$role.p${"%03d".format(part + 1)}.cge"

    /**
     * Bytes needed on disk to upload files of these sizes: the largest encrypted part, the only thing written. Unlike
     * iOS (`PartLayout.spaceNeeded`), nothing is exported first: Android reads the photo straight from MediaStore.
     */
    fun spaceNeeded(sizes: List<Long>, limit: Long): Long =
        sizes.maxOfOrNull { PartLayout.forUpload(FileCrypto.encryptedSize(it), limit).sizeOfPart(0) } ?: 0

    /** Room left for the system and TDLib's own files while a part is on disk. */
    const val SPACE_MARGIN = 200L shl 20
}

/**
 * Which backed-up photos may be removed from the phone (iOS `FreeUpSpaceService` and `EditCheck.mayLoseEdit`). Only
 * items complete in the cloud, checked in Telegram in the last day, and unchanged on the phone since their backup.
 */
object FreeUpSpace {
    const val VERIFICATION_LIFETIME_MS = 24L * 60 * 60 * 1000

    /** Backed up, complete, and linked to a photo on this phone. */
    fun isCandidate(item: LibraryItem): Boolean = item.status == ItemStatus.BackedUp && item.localId != null && item.isCompleteInCloud

    /**
     * Changed on the phone since its backup: removing it could lose that change. Android keeps no separate edit, so an
     * edit shows as a new size or a newer modification date (a minute's slack: favoriting moves the date too).
     */
    fun mayHaveChanged(item: LibraryItem, phoneSize: Long, phoneModified: Long?): Boolean {
        if (phoneSize != item.fileSize) return true
        val since = item.assetModifiedAt ?: return false
        return phoneModified != null && phoneModified > since + 60_000
    }

    fun isFreshlyVerified(item: LibraryItem, now: Long): Boolean = item.verifiedAt?.let { now - it in 0 until VERIFICATION_LIFETIME_MS } ?: false

    fun bytes(items: List<LibraryItem>): Long = items.sumOf { it.fileSize + (it.pairedVideoSize ?: 0) }
}

/** The same content backed up as more than one item (iOS `CloudDuplicateGroup`): [keep] stays, [extras] can go. */
data class CloudDuplicateGroup(val keep: LibraryItem, val extras: List<LibraryItem>) {
    val wastedBytes: Long get() = extras.sumOf { it.fileSize + (it.pairedVideoSize ?: 0) + (it.editedSize ?: 0) }

    companion object {
        /** Keeps the one linked to a photo on this phone, else the oldest upload. Newest groups first. */
        fun find(backedUp: List<LibraryItem>, onPhone: Set<String>): List<CloudDuplicateGroup> =
            backedUp.filter { it.sha256.isNotEmpty() && it.status == ItemStatus.BackedUp }.groupBy { it.sha256 }.values
                .filter { it.size > 1 }
                .map { group ->
                    val sorted = group.sortedWith(
                        compareBy<LibraryItem> { if (it.localId?.let(onPhone::contains) == true) 0 else 1 }.thenBy { it.uploadedAt ?: Long.MAX_VALUE },
                    )
                    CloudDuplicateGroup(sorted.first(), sorted.drop(1))
                }
                .sortedByDescending { it.keep.createdAt ?: Long.MIN_VALUE }
    }
}
