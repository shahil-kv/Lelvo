package app.lelvo.core.index

import kotlin.math.ceil

/**
 * Recently Deleted (iOS `CloudTrash`): an item deleted from the cloud keeps its messages for 30 days, then they're
 * deleted. The date comes from the Telegram note, so every device counts the same days.
 */
object CloudTrash {
    const val RETENTION_MS = 30L * 24 * 3600 * 1000

    /** Days until the messages are deleted, rounded up like Photos: 30 right after deleting, 1 on the last day. */
    fun daysLeft(item: LibraryItem, nowMs: Long): Int {
        val at = item.trashedAt ?: return (RETENTION_MS / 86_400_000L).toInt()
        // Never more than 30: the date is Telegram's, and a phone clock behind it would round up to 31.
        return ceil((at + RETENTION_MS - nowMs) / 86_400_000.0).toInt().coerceIn(0, (RETENTION_MS / 86_400_000L).toInt())
    }

    /** A missing date never expires: keep data when in doubt. */
    fun isExpired(item: LibraryItem, nowMs: Long): Boolean {
        if (item.status != ItemStatus.Trashed) return false
        val at = item.trashedAt ?: return false
        return nowMs >= at + RETENTION_MS
    }

    /** Into Recently Deleted at [atMs] (iOS `CloudTrash.trash`): only a backed-up item, or one stranded in the cloud. */
    fun trash(item: LibraryItem, atMs: Long): LibraryItem =
        if (item.status == ItemStatus.BackedUp || item.isStrandedInCloud) item.copy(status = ItemStatus.Trashed, trashedAt = atMs) else item

    /**
     * The date to record for a delete. A phone clock set behind would start the 30 days in the past, so the later of
     * the two clocks wins: a wrong clock can only keep an item longer.
     */
    fun deletedAt(deviceMs: Long, telegramMs: Long?): Long = telegramMs?.let { maxOf(it, deviceMs) } ?: deviceMs

    /**
     * The time to test expiry against: the earlier clock, so neither can delete early alone. Null without Telegram's
     * time, and nothing expires then: a phone clock set ahead must not be able to delete anything.
     */
    fun expiryClock(deviceMs: Long, telegramMs: Long?): Long? = telegramMs?.let { minOf(it, deviceMs) }

    /** Message ids in one delete request; Telegram takes up to 100 per call in a channel. */
    const val MAX_MESSAGES_PER_DELETE = 100

    /**
     * Groups items for deletion so 50 photos take one request instead of 50. An item's messages stay together, so a
     * failed request can't leave it half deleted; an item with more messages than the limit goes alone.
     */
    fun deleteBatches(items: List<LibraryItem>): List<List<LibraryItem>> {
        val batches = ArrayList<List<LibraryItem>>()
        var current = ArrayList<LibraryItem>()
        var count = 0
        for (item in items) {
            val messages = item.allMessageIds.size
            if (current.isNotEmpty() && count + messages > MAX_MESSAGES_PER_DELETE) {
                batches += current
                current = ArrayList()
                count = 0
            }
            current += item
            count += messages
        }
        if (current.isNotEmpty()) batches += current
        return batches
    }

    /** What Recently Deleted lists: the most recently deleted first. */
    fun items(all: List<LibraryItem>): List<LibraryItem> =
        all.filter { it.status == ItemStatus.Trashed }.sortedByDescending { it.trashedAt ?: Long.MAX_VALUE }
}
