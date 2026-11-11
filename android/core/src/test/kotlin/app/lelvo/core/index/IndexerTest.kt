package app.lelvo.core.index

import app.lelvo.core.format.CaptionMeta
import app.lelvo.core.format.CloudMessage
import app.lelvo.core.format.Kind
import app.lelvo.core.format.Role
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

// Mirrors LibraryIndexerTests in Packages/LelvoCore/Tests (the build half; the delete half lands with Phase C).
class IndexerTest {
    private val id = "0b7c0e3e-6f1e-4c55-9a33-1f3f0c0a9d10"

    private fun meta(role: Role = Role.ORIGINAL, kind: Kind = Kind.PHOTO, part: List<Long>? = null) = CaptionMeta(
        id = id, r = role, k = kind, h = (if (role == Role.ORIGINAL) "a" else "b").repeat(64),
        n = if (role == Role.PAIRED_VIDEO) "IMG_1.MOV" else "IMG_1.HEIC", s = 1000, t = 1_700_000_000, g = listOf(1.5, 2.5), p = part,
    )

    private fun msg(mid: Long, role: Role = Role.ORIGINAL, kind: Kind = Kind.PHOTO, part: List<Long>? = null, size: Long = 100) =
        CloudMessage(mid, meta(role, kind, part), "f$mid", "u$mid", size)

    private fun CloudMessage.with(change: (CaptionMeta) -> CaptionMeta) = copy(meta = change(meta))

    @Test fun singlePhotoIsComplete() {
        val r = LibraryIndexer.build(listOf(msg(10)))
        val item = r.items.single()
        assertEquals(ItemStatus.BackedUp, item.status)
        assertEquals(listOf(10L), item.parts.getValue("o").map { it.messageId })
        assertEquals(1.5, item.latitude)
        assertEquals(1_700_000_000_000L, item.createdAt)
        assertTrue(r.orphanMessageIds.isEmpty())
    }

    @Test fun duplicatesKeepLowestMessageId() {
        val r = LibraryIndexer.build(listOf(msg(30), msg(10), msg(20)))
        assertEquals(listOf(10L), r.items[0].parts.getValue("o").map { it.messageId })
        assertEquals(listOf(20L, 30L), r.orphanMessageIds)
    }

    @Test fun editedVersionIsRequiredWhenDeclared() {
        val original = msg(1).with { it.copy(ed = 1) }
        val missing = LibraryIndexer.build(listOf(original))
        assertTrue(missing.items[0].hasEdit)
        assertEquals(ItemStatus.Failed, missing.items[0].status)

        val edited = msg(2, Role.EDITED).with { it.copy(n = "FullSizeRender.heic", s = 900) }
        val complete = LibraryIndexer.build(listOf(original, edited)).items[0]
        assertEquals(ItemStatus.BackedUp, complete.status)
        assertEquals("FullSizeRender.heic", complete.editedName)
        assertEquals(900L, complete.editedSize)
        assertEquals(listOf(2L), complete.parts.getValue("e").map { it.messageId })
    }

    @Test fun uneditedItemNeedsNoEditedVersion() {
        val item = LibraryIndexer.build(listOf(msg(1))).items[0]
        assertTrue(!item.hasEdit)
        assertEquals(ItemStatus.BackedUp, item.status)
    }

    @Test fun livePhotoNeedsPairedVideo() {
        assertEquals(ItemStatus.Failed, LibraryIndexer.build(listOf(msg(1, kind = Kind.LIVE))).items[0].status)
        val complete = LibraryIndexer.build(listOf(msg(1, kind = Kind.LIVE), msg(2, Role.PAIRED_VIDEO, Kind.LIVE))).items[0]
        assertEquals(ItemStatus.BackedUp, complete.status)
        assertEquals(ItemKind.LivePhoto, complete.kind)
        assertEquals("IMG_1.MOV", complete.pairedVideoName)
        assertEquals(listOf(1L, 2L), complete.allMessageIds)
    }

    @Test fun splitPartsMustAllBePresent() {
        val ps = 1999L * 1_048_576
        val missing = LibraryIndexer.build(listOf(msg(1, kind = Kind.VIDEO, part = listOf(0, 3, ps)), msg(3, kind = Kind.VIDEO, part = listOf(2, 3, ps))))
        assertEquals(ItemStatus.Failed, missing.items[0].status)
        val all = LibraryIndexer.build(
            listOf(msg(3, kind = Kind.VIDEO, part = listOf(2, 3, ps)), msg(1, kind = Kind.VIDEO, part = listOf(0, 3, ps)), msg(2, kind = Kind.VIDEO, part = listOf(1, 3, ps))),
        )
        assertEquals(ItemStatus.BackedUp, all.items[0].status)
        assertEquals(listOf(1L, 2L, 3L), all.items[0].parts.getValue("o").map { it.messageId })
    }

    @Test fun aGapInThePartsIsIncompleteEvenWhenTheCountLooksRight() {
        // Parts 0 and 2 of a declared 2: the count matches but part 1 is missing.
        val r = LibraryIndexer.build(listOf(msg(1, part = listOf(0, 2, 10)), msg(2, part = listOf(2, 2, 10))))
        assertEquals(ItemStatus.Failed, r.items[0].status)
    }

    @Test fun encryptedItemsRequireThumbnail() {
        val o = msg(1).with { it.copy(e = 1) }
        assertEquals(ItemStatus.Failed, LibraryIndexer.build(listOf(o)).items[0].status)
        val t = msg(2, Role.THUMBNAIL).with { it.copy(e = 1) }
        val item = LibraryIndexer.build(listOf(o, t)).items[0]
        assertEquals(ItemStatus.BackedUp, item.status)
        assertTrue(item.encrypted)
    }

    @Test fun onlyCopiesLeftAreOrphansNotAnItem() {
        val r = LibraryIndexer.build(listOf(msg(5, Role.THUMBNAIL), msg(6, Role.SCREEN_COPY)))
        assertTrue(r.items.isEmpty())
        assertEquals(listOf(5L, 6L), r.orphanMessageIds)
    }

    @Test fun roleDetailsAreKept() {
        val item = LibraryIndexer.build(
            listOf(
                msg(1).with { it.copy(m = "image/heic", tz = 330, l = "asset-1", wh = listOf(4032, 3024), a = listOf("Paris"), fav = 1, hid = 1) },
                msg(2, Role.SMOOTH_PREVIEW).with { it.copy(h = "f".repeat(64)) },
            ),
        ).items[0]
        assertEquals("image/heic", item.mimeType)
        assertEquals(330, item.tzOffsetMinutes)
        assertEquals("asset-1", item.sourceLocalId)
        assertEquals(4032 to 3024, item.width to item.height)
        assertEquals(listOf("Paris"), item.albums)
        assertTrue(item.favorite && item.hidden)
        assertEquals("f".repeat(64), item.roleHashes["sp"])
        assertEquals("a".repeat(64), item.sha256)
    }

    @Test fun newestFirst() {
        val other = "1b7c0e3e-6f1e-4c55-9a33-1f3f0c0a9d10"
        val r = LibraryIndexer.build(listOf(msg(1), CloudMessage(2, meta().copy(id = other, t = 1_800_000_000), "f", "u", 1)))
        assertEquals(listOf(other, id), r.items.map { it.id })
        assertNotEquals(r.items[0].createdAt, r.items[1].createdAt)
    }
}
