package app.lelvo.core

import app.lelvo.core.format.TrashLog
import app.lelvo.core.index.ItemKind
import app.lelvo.core.index.ItemStatus
import app.lelvo.core.index.LibraryItem
import app.lelvo.core.index.RemoteFile
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

// Mirrors the action half of the iOS TrashLogTests.
class TrashActionTest {
    private val day0 = 100L * 86400

    private fun item(status: ItemStatus = ItemStatus.BackedUp, localId: String? = "A") = LibraryItem(
        id = "item-1", localId = localId, sha256 = "h", filename = "IMG_1.HEIC", kind = ItemKind.Photo, createdAt = null,
        fileSize = 10, status = status, parts = mapOf("o" to listOf(RemoteFile(1, "f", "u", 10))), expectedParts = mapOf("o" to 1),
    )

    private fun note(id: Long, op: TrashLog.Op, day: Long = 0) = TrashLog.Note(id, day0 + day * 86400, op, listOf("item-1"))

    @Test fun deleteTrashesWithTheNotesDate() {
        val n = note(1, TrashLog.Op.DELETE, day = 2)
        val action = TrashLog.action(item(), n, messagesSeen = false)
        assertEquals(TrashLog.Action.Trash(n.date * 1000), action)
        val trashed = TrashLog.apply(action, item())!!
        assertEquals(ItemStatus.Trashed, trashed.status)
        assertEquals(n.date * 1000, trashed.trashedAt)
    }

    @Test fun aDifferentLocalDateTakesTheSharedDate() {
        val n = note(1, TrashLog.Op.DELETE, day = 1)
        val here = item().copy(status = ItemStatus.Trashed, trashedAt = day0 * 1000)
        assertEquals(TrashLog.Action.Trash(n.date * 1000), TrashLog.action(here, n, false))
        assertEquals(TrashLog.Action.None, TrashLog.action(here.copy(trashedAt = n.date * 1000), n, false))
    }

    @Test fun recoverBringsItBack() {
        val trashed = item().copy(status = ItemStatus.Trashed, trashedAt = day0 * 1000)
        val n = note(2, TrashLog.Op.RECOVER)
        val action = TrashLog.action(trashed, n, false)
        assertEquals(TrashLog.Action.Recover, action)
        val back = TrashLog.apply(action, trashed)!!
        assertEquals(ItemStatus.BackedUp, back.status)
        assertNull(back.trashedAt)
        assertEquals(TrashLog.Action.None, TrashLog.action(back, n, false))
    }

    @Test fun uploadsWaitForTheirNote() {
        for (status in listOf(ItemStatus.Queued, ItemStatus.Uploading, ItemStatus.Failed)) {
            assertEquals(TrashLog.Action.None, TrashLog.action(item(status), note(1, TrashLog.Op.DELETE), false))
            assertEquals(TrashLog.Action.None, TrashLog.action(item(status), note(1, TrashLog.Op.GONE), false))
        }
    }

    @Test fun strandedItemsFollowTheirNote() {
        val stranded = item(ItemStatus.Failed, localId = null)
        assertEquals(TrashLog.Action.Trash(day0 * 1000), TrashLog.action(stranded, note(1, TrashLog.Op.DELETE), false))
    }

    @Test fun goneRemovesUnlessTheMessagesAreStillThere() {
        val n = note(1, TrashLog.Op.GONE)
        assertEquals(TrashLog.Action.Remove, TrashLog.action(item(), n, messagesSeen = false))
        assertEquals(TrashLog.Action.Trash(n.date * 1000), TrashLog.action(item(), n, messagesSeen = true))
    }
}
