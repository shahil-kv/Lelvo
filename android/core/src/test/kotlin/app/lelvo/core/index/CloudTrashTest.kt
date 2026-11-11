package app.lelvo.core.index

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class CloudTrashTest {
    private val day = 86_400_000L
    private fun item(at: Long?, status: ItemStatus = ItemStatus.Trashed, id: String = "a") =
        LibraryItem(id, null, "h", "a.jpg", ItemKind.Photo, 0, fileSize = 1, status = status, trashedAt = at)

    @Test fun daysLeftRoundUpLikePhotos() {
        assertEquals(30, CloudTrash.daysLeft(item(0), 0))
        assertEquals(30, CloudTrash.daysLeft(item(0), 1))
        assertEquals(1, CloudTrash.daysLeft(item(0), 29 * day + 1))
        assertEquals(0, CloudTrash.daysLeft(item(0), 31 * day))
        assertEquals(30, CloudTrash.daysLeft(item(null), 99 * day))
    }

    @Test fun onlyDatedTrashedItemsExpire() {
        assertTrue(CloudTrash.isExpired(item(0), 30 * day))
        assertFalse(CloudTrash.isExpired(item(0), 30 * day - 1))
        assertFalse(CloudTrash.isExpired(item(null), 99 * day))
        assertFalse(CloudTrash.isExpired(item(0, ItemStatus.BackedUp), 99 * day))
    }

    @Test fun listsTrashedNewestFirst() {
        val list = CloudTrash.items(listOf(item(1, id = "old"), item(5, id = "new"), item(3, ItemStatus.BackedUp, id = "kept")))
        assertEquals(listOf("new", "old"), list.map { it.id })
    }
}
