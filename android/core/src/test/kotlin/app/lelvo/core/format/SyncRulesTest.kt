package app.lelvo.core.format

import app.lelvo.core.format.PhotosFavorite.Decision
import app.lelvo.core.index.CloudTrash
import app.lelvo.core.index.ItemKind
import app.lelvo.core.index.ItemStatus
import app.lelvo.core.index.LibraryItem
import app.lelvo.core.index.RemoteFile
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

// Mirrors iOS PhotosFavoriteTests and the follow/purge half of TrashLogTests.
class SyncRulesTest {
    @Test fun agreeingSidesChangeNothing() {
        assertEquals(Decision.Remember, PhotosFavorite.decide(true, null, true, true))
        assertEquals(Decision.Remember, PhotosFavorite.decide(false, true, false, false))
    }

    @Test fun unknownLibraryValueChangesNothing() {
        assertEquals(Decision.Remember, PhotosFavorite.decide(true, null, null, false))
        assertEquals(Decision.Remember, PhotosFavorite.decide(true, false, null, false))
        assertNull(PhotosFavorite.libraryValue(favorite = false, noteDecides = false))
        assertEquals(false, PhotosFavorite.libraryValue(favorite = false, noteDecides = true))
        assertEquals(true, PhotosFavorite.libraryValue(favorite = true, noteDecides = false))
    }

    @Test fun aChangeFromAnotherDeviceReachesThePhone() {
        assertEquals(Decision.SetOnPhone(false), PhotosFavorite.decide(true, null, false, true))
        assertEquals(Decision.SetOnPhone(false), PhotosFavorite.decide(true, true, false, true))
        assertEquals(Decision.SetOnPhone(true), PhotosFavorite.decide(false, false, true, true))
    }

    @Test fun aChangeOnThePhoneIsSent() {
        assertEquals(Decision.SendNote(true), PhotosFavorite.decide(true, false, false, true))
        assertEquals(Decision.SendNote(false), PhotosFavorite.decide(false, true, true, false))
        assertEquals(Decision.SendNote(true), PhotosFavorite.decide(true, null, false, false))
    }

    @Test fun twoDevicesFollowEachOther() {
        class Device(var phone: Boolean, var lastSeen: Boolean?)
        var library = true
        val a = Device(true, null)
        val b = Device(true, null)
        fun check(d: Device) {
            when (val r = PhotosFavorite.decide(d.phone, d.lastSeen, library, true)) {
                Decision.Remember -> Unit
                is Decision.SetOnPhone -> d.phone = r.value
                is Decision.SendNote -> library = r.value
            }
            d.lastSeen = d.phone
        }
        check(a); check(b)
        library = false
        b.phone = false
        check(b); check(a)
        assertTrue(!a.phone && !b.phone)
        a.phone = true
        check(a); check(b)
        assertTrue(a.phone && b.phone && library)
        check(a); check(b)
        assertTrue(a.phone && b.phone && library)
    }

    private fun item(id: String, status: ItemStatus = ItemStatus.Trashed, messages: List<Long> = listOf(1), localId: String? = null) = LibraryItem(
        id = id, localId = localId, sha256 = "h", filename = "a.jpg", kind = ItemKind.Photo, createdAt = null, fileSize = 1, status = status,
        parts = mapOf("o" to messages.map { RemoteFile(it, "f$it", "u$it", 1) }), expectedParts = mapOf("o" to messages.size),
    )

    private fun note(mid: Long, op: TrashLog.Op, vararg ids: String) = TrashLog.Note(mid, 0, op, ids.toList())

    @Test fun oldItemsGetOneNote() {
        val trashed = listOf(item("a"), item("b"), item("c"))
        val notes = listOf(note(10, TrashLog.Op.DELETE, "a"), note(11, TrashLog.Op.RECOVER, "b"))
        assertEquals(listOf("b"), TrashLog.itemsNeedingANote(trashed, notes, waiting = setOf("c")).map { it.id })
    }

    @Test fun confirmsOnlyTheNotesKeepingItemsDeleted() {
        val trashed = listOf(item("a"), item("b"))
        val notes = listOf(note(10, TrashLog.Op.DELETE, "a"), note(12, TrashLog.Op.DELETE, "a"), note(11, TrashLog.Op.DELETE, "b"))
        assertEquals(setOf(12L), TrashLog.notesToConfirm(trashed, notes, waiting = setOf("b")))
    }

    @Test fun uncoveredItemsFollowTelegram() {
        val trashed = listOf(item("a"), item("b"), item("c"), item("d"))
        val notes = listOf(note(10, TrashLog.Op.DELETE, "a", "b"), note(11, TrashLog.Op.RECOVER, "c"))
        // Note 10 was removed by another device: a and b are uncovered; c's newest note is a recover; d is waiting.
        val result = TrashLog.uncovered(trashed, notes, stillInChannel = setOf(11), waiting = setOf("d"))
        assertEquals(listOf("a", "b", "c"), result.map { it.id })
        assertEquals(emptyList(), TrashLog.uncovered(trashed, notes, setOf(10, 11), setOf("d")).filter { it.id != "c" })
    }

    @Test fun goneOnlyWhenEveryMessageIsGone() {
        val two = item("a", messages = listOf(1, 2))
        assertTrue(TrashLog.allMessagesGone(two, existing = emptySet()))
        assertFalse(TrashLog.allMessagesGone(two, existing = setOf(2)))
        assertFalse(TrashLog.allMessagesGone(item("b", messages = emptyList()), existing = emptySet()))
    }

    @Test fun purgeNeedsADeleteNoteAndNothingWaiting() {
        val a = item("a")
        assertTrue(TrashLog.mayPurge(a, note(1, TrashLog.Op.DELETE, "a"), emptySet()))
        assertFalse(TrashLog.mayPurge(a, note(1, TrashLog.Op.DELETE, "a"), setOf("a")))
        assertFalse(TrashLog.mayPurge(a, note(1, TrashLog.Op.RECOVER, "a"), emptySet()))
        assertFalse(TrashLog.mayPurge(a, null, emptySet()))
    }

    @Test fun clocksCanOnlyKeepItemsLonger() {
        assertEquals(200, CloudTrash.deletedAt(100, 200))
        assertEquals(200, CloudTrash.deletedAt(200, 100))
        assertEquals(100, CloudTrash.deletedAt(100, null))
        assertEquals(100, CloudTrash.expiryClock(100, 200))
        assertEquals(100, CloudTrash.expiryClock(200, 100))
        assertNull(CloudTrash.expiryClock(100, null))
    }

    @Test fun trashTakesOnlyBackedUpOrStranded() {
        assertEquals(ItemStatus.Trashed, CloudTrash.trash(item("a", ItemStatus.BackedUp), 5).status)
        assertEquals(5L, CloudTrash.trash(item("a", ItemStatus.BackedUp), 5).trashedAt)
        assertEquals(ItemStatus.Queued, CloudTrash.trash(item("a", ItemStatus.Queued, localId = "L"), 5).status)
        assertEquals(ItemStatus.Trashed, CloudTrash.trash(item("a", ItemStatus.Failed), 5).status)
    }

    @Test fun deleteBatchesKeepAnItemsMessagesTogether() {
        val items = listOf(item("a", messages = (1L..60L).toList()), item("b", messages = (61L..100L).toList()),
            item("c", messages = listOf(101)), item("d", messages = (200L..350L).toList()))
        assertEquals(listOf(listOf("a", "b"), listOf("c"), listOf("d")), CloudTrash.deleteBatches(items).map { b -> b.map { it.id } })
    }
}
