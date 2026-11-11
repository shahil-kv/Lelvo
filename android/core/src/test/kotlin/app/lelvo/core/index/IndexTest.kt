package app.lelvo.core.index

import app.lelvo.core.demo.DemoLibrary
import java.io.File
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

private val utc: ZoneId = ZoneOffset.UTC

private fun item(id: String, at: String?, status: ItemStatus = ItemStatus.BackedUp, hidden: Boolean = false) = LibraryItem(
    id = id, localId = null, sha256 = "0".repeat(64), filename = "$id.jpg", kind = ItemKind.Photo,
    createdAt = at?.let { Instant.parse(it).toEpochMilli() }, fileSize = 1, status = status, hidden = hidden,
)

class TimelineTest {
    private val today = LocalDate.parse("2026-11-11")

    @Test fun onlyBackedUpAndNotHiddenItemsShow() {
        val shown = Timeline.visible(
            listOf(
                item("a", "2026-11-11T10:00:00Z"),
                item("b", "2026-11-11T09:00:00Z", status = ItemStatus.Trashed),
                item("c", "2026-11-11T08:00:00Z", hidden = true),
                item("d", "2026-11-11T07:00:00Z", status = ItemStatus.Queued),
            ),
        )
        assertEquals(listOf("a"), shown.map { it.id })
    }

    @Test fun newestFirstAndUndatedLast() {
        val shown = Timeline.visible(listOf(item("old", "2020-01-01T00:00:00Z"), item("none", null), item("new", "2026-01-01T00:00:00Z")))
        assertEquals(listOf("new", "old", "none"), shown.map { it.id })
    }

    @Test fun daySectionsSayTodayAndYesterday() {
        val items = Timeline.visible(
            listOf(
                item("t1", "2026-11-11T10:00:00Z"), item("t2", "2026-11-11T01:00:00Z"),
                item("y", "2026-11-10T23:59:00Z"), item("o", "2026-10-02T12:00:00Z"), item("u", null),
            ),
        )
        val sections = Timeline.group(items, Timeline.Grouping.Day, utc, today)
        assertEquals(
            listOf(Timeline.Title.Today, Timeline.Title.Yesterday, Timeline.Title.Day(LocalDate.parse("2026-10-02")), Timeline.Title.Unknown),
            sections.map { it.title },
        )
        assertEquals(listOf(2, 1, 1, 1), sections.map { it.items.size })
        assertEquals(sections.size, sections.map { it.key }.toSet().size)
    }

    @Test fun daysUseTheLocalZone() {
        // 23:30 UTC on the 10th is already the 11th in India.
        val items = listOf(item("a", "2026-11-10T23:30:00Z"))
        val india = ZoneId.of("Asia/Kolkata")
        assertEquals(Timeline.Title.Today, Timeline.group(items, Timeline.Grouping.Day, india, today).single().title)
    }

    @Test fun monthAndYearGrouping() {
        val items = Timeline.visible(listOf(item("a", "2026-11-01T10:00:00Z"), item("b", "2026-10-31T10:00:00Z"), item("c", "2025-10-31T10:00:00Z")))
        assertEquals(3, Timeline.group(items, Timeline.Grouping.Month, utc, today).size)
        val years = Timeline.group(items, Timeline.Grouping.Year, utc, today)
        assertEquals(listOf(Timeline.Title.Year(2026), Timeline.Title.Year(2025)), years.map { it.title })
    }
}

class ItemExtrasTest {
    @Test fun roundTrip() {
        val item = item("a", "2026-11-11T10:00:00Z").copy(
            albums = listOf("Paris", "Café"),
            parts = mapOf("o" to listOf(RemoteFile(1, "f1", "u1", 10), RemoteFile(2, "f2", "u2", 5)), "t" to listOf(RemoteFile(3, "f3", "u3", 1))),
            expectedParts = mapOf("o" to 2, "t" to 1),
        )
        val full = item.copy(
            encrypted = true, mimeType = "image/heic", codec = "hevc", hdr = 2, tzOffsetMinutes = 330, sourceLocalId = "asset-1",
            hasEdit = true, roleHashes = mapOf("o" to "a".repeat(64)), roleNames = mapOf("ra" to "IMG_1.DNG"), pairedVideoName = "IMG_1.MOV",
            pairedVideoSize = 7, editedName = "FullSizeRender.heic", editedSize = 9, lastError = "x",
        )
        assertEquals(full, ItemExtras.apply(full.copy(albums = emptyList(), parts = emptyMap(), encrypted = false), ItemExtras.decode(ItemExtras.encode(full))))
    }

    @Test fun unreadableExtrasAreEmptyNotACrash() {
        val back = ItemExtras.decode("not json")
        assertTrue(ItemExtras.decode("{}").parts.isEmpty())
        assertTrue(back.parts.isEmpty())
        assertTrue(back.albums.isEmpty())
    }

    @Test fun completeInCloudNeedsEveryPart() {
        val one = RemoteFile(1, "f", "u", 1)
        val base = item("a", null)
        assertFalse(base.copy(parts = mapOf("o" to listOf(one)), expectedParts = mapOf("o" to 2)).isCompleteInCloud)
        assertTrue(base.copy(parts = mapOf("o" to listOf(one, one)), expectedParts = mapOf("o" to 2)).isCompleteInCloud)
    }
}

class DemoLibraryTest {
    private val manifest = File(System.getProperty("lelvo.demo"), "manifest.json").readText()
    private val today = LocalDate.parse("2026-11-11")
    private val now = Instant.parse("2026-11-11T23:00:00Z")

    @Test fun fnv1aMatchesTheReferenceValue() {
        // FNV-1a 64 of "a", from the FNV reference.
        assertEquals(0xaf63dc4c8601ec8cuL.toLong(), DemoLibrary.stableHash("a"))
    }

    @Test fun readsTheBundledManifest() {
        val entries = DemoLibrary.entries(manifest)
        assertEquals(42, entries.size)
        assertEquals(6, entries.count { it.pending })
        assertEquals(2, entries.count { it.kind == "video" })
    }

    @Test fun itemsLookLikeTheIPhoneDemo() {
        val entries = DemoLibrary.entries(manifest)
        val items = entries.map { DemoLibrary.item(it, today, utc, now) }
        assertTrue(items.all { it.id.startsWith("demo-") && it.status == ItemStatus.BackedUp && it.isCompleteInCloud })
        assertTrue(items.all { it.sha256.length == 64 && it.sha256.startsWith("0".repeat(48)) })
        assertTrue(items.all { (it.createdAt ?: 0) <= now.toEpochMilli() })
        val video = items.first { it.kind == ItemKind.Video }
        assertEquals(setOf("o", "sp"), video.parts.keys)
        val first = DemoLibrary.item(entries.first { it.file == "photo01.jpg" }, today, utc, now)
        // Day 0 at 09:00 plus 0 minutes.
        assertEquals(Instant.parse("2026-11-11T09:00:00Z").toEpochMilli(), first.createdAt)
        assertEquals(java.lang.Long.remainderUnsigned(DemoLibrary.stableHash("photo01.jpg"), 1_000_000), first.parts.getValue("o").single().messageId)
        assertEquals("photo01.jpg", DemoLibrary.assetName(first))
        assertNull(DemoLibrary.assetName(item("x", null)))
    }

    @Test fun aDateLaterThanNowIsClamped() {
        val late = DemoLibrary.entries(manifest).first { it.daysAgo == 0 }
        val early = Instant.parse("2026-11-11T08:00:00Z")
        assertEquals(early.toEpochMilli(), DemoLibrary.item(late, today, utc, early).createdAt)
    }
}
