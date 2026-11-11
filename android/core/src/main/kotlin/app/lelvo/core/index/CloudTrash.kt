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
        return maxOf(0, ceil((at + RETENTION_MS - nowMs) / 86_400_000.0).toInt())
    }

    /** A missing date never expires: keep data when in doubt. */
    fun isExpired(item: LibraryItem, nowMs: Long): Boolean {
        if (item.status != ItemStatus.Trashed) return false
        val at = item.trashedAt ?: return false
        return nowMs >= at + RETENTION_MS
    }

    /** What Recently Deleted lists: the most recently deleted first. */
    fun items(all: List<LibraryItem>): List<LibraryItem> =
        all.filter { it.status == ItemStatus.Trashed }.sortedByDescending { it.trashedAt ?: Long.MAX_VALUE }
}
