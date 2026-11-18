package app.lelvo.core.index

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class GalleryTest {
    private fun item(id: String, at: Long?, localId: String? = null, status: ItemStatus = ItemStatus.BackedUp, fav: Boolean = false) = LibraryItem(
        id = id, localId = localId, sha256 = "h", filename = "$id.jpg", kind = ItemKind.Photo, createdAt = at, fileSize = 1,
        status = status, favorite = fav,
    )

    private fun asset(id: String, at: Long?, video: Boolean = false, fav: Boolean = false) = PhoneAsset(id, at, video, isFavorite = fav)

    @Test fun phoneAndCloudMergeNewestFirst() {
        val entries = Gallery.merge(
            assets = listOf(asset("p3", 300), asset("p1", 100)),
            items = listOf(item("c2", 200), item("c4", 400), item("linked", 300, localId = "p3")),
        )
        assertEquals(listOf("cloud-c4", "p3", "cloud-c2", "p1"), entries.map { it.id })
        assertEquals(BackupBadge.BackedUp, entries[1].badge)
        assertEquals(BackupBadge.CloudOnly, entries[0].badge)
        assertEquals(BackupBadge.PhoneOnly, entries[3].badge)
    }

    // iOS `merge(aliases:)`: a second phone copy of a backed-up photo shows its badge, and the item has no cloud tile.
    @Test fun aliasesShowTheirItemsBadge() {
        val entries = Gallery.merge(
            assets = listOf(asset("copy", 200), asset("own", 100)),
            items = listOf(item("x", 200, localId = "gone-elsewhere")),
            aliases = mapOf("copy" to "x"),
        )
        assertEquals(listOf("copy", "own"), entries.map { it.id })
        assertEquals(BackupBadge.BackedUp, entries[0].badge)
        assertEquals(BackupBadge.PhoneOnly, entries[1].badge)
    }

    @Test fun onlyBackedUpCloudItemsShowOnTheirOwn() {
        val entries = Gallery.merge(emptyList(), listOf(item("a", 1, status = ItemStatus.Failed), item("b", 2, status = ItemStatus.Trashed), item("c", 3)))
        assertEquals(listOf("cloud-c"), entries.map { it.id })
    }

    @Test fun anItemWhosePhotoLeftThePhoneShowsAsCloudOnly() {
        val entries = Gallery.merge(emptyList(), listOf(item("a", 1, localId = "gone")))
        assertEquals(BackupBadge.CloudOnly, entries.single().badge)
    }

    @Test fun badgesFollowTheItemStatus() {
        val a = asset("p", 1)
        assertEquals(BackupBadge.Waiting, GalleryEntry("p", 1, a, item("i", 1, "p", ItemStatus.Queued)).badge)
        assertEquals(BackupBadge.Uploading, GalleryEntry("p", 1, a, item("i", 1, "p", ItemStatus.Uploading)).badge)
        assertEquals(BackupBadge.Failed, GalleryEntry("p", 1, a, item("i", 1, "p", ItemStatus.Failed)).badge)
        assertEquals(BackupBadge.PhoneOnly, GalleryEntry("p", 1, a, item("i", 1, "p", ItemStatus.Trashed)).badge)
    }

    @Test fun thePhoneDecidesFavoritesForItsPhotos() {
        val entry = GalleryEntry("p", 1, asset("p", 1, fav = false), item("i", 1, "p", fav = true))
        assertTrue(!entry.isFavorite)
        assertTrue(GalleryFilter.Favorites.matches(entry), "Either side being a favorite counts for the filter, as iOS")
    }

    @Test fun undatedEntriesGoLast() {
        val entries = Gallery.merge(listOf(asset("p", null)), listOf(item("c", 5)))
        assertEquals(listOf("cloud-c", "p"), entries.map { it.id })
        assertNull(entries.last().date)
    }

    @Test fun aPhoneFileWithoutACaptureDateTakesTheBackupsDate() {
        // Saved back from the cloud with no EXIF date: Android records none, so it would sit under the day it was added.
        val saved = PhoneAsset("p2", null, false, addedAt = 900)
        val entries = Gallery.merge(
            assets = listOf(saved, asset("p1", 300)),
            items = listOf(item("c", 100, localId = "p2")),
        )
        assertEquals(listOf("p1", "p2"), entries.map { it.id })
        assertEquals(100L, entries[1].date)
    }

    @Test fun anUnlinkedPhoneFileWithoutACaptureDateUsesWhenItWasAdded() {
        val entries = Gallery.merge(listOf(PhoneAsset("p", null, false, addedAt = 500), asset("q", 400)), emptyList())
        assertEquals(listOf("p", "q"), entries.map { it.id })
        assertEquals(500L, entries[0].date)
    }

    @Test fun notBackedUpFilter() {
        assertTrue(GalleryFilter.NotBackedUp.matches(GalleryEntry("p", 1, asset("p", 1), null)))
        assertTrue(!GalleryFilter.NotBackedUp.matches(GalleryEntry("cloud-c", 1, null, item("c", 1))))
    }

    @Test fun aFileWithoutCaptureDateUsesItsOwnDatesNotTheDayItWasCopied() {
        // A screenshot from 2025 copied to this phone today: modified time 2025, added today.
        val modified = 1_740_000_000L
        val addedToday = 1_794_490_000_000L
        assertEquals(modified * 1000, captureDate(null, modified, addedToday))
        // A capture date always wins.
        assertEquals(5L, captureDate(5L, modified, addedToday))
        // Edited after it was added: the earlier date.
        assertEquals(addedToday, captureDate(null, addedToday / 1000 + 3600, addedToday))
        // Only one of them known, or neither.
        assertEquals(addedToday, captureDate(null, null, addedToday))
        assertEquals(addedToday, captureDate(null, 0, addedToday))
        assertEquals(modified * 1000, captureDate(null, modified, null))
        assertNull(captureDate(null, null, null))
    }

    @Test fun mergePlacesScreenshotsByTheirFileDate() {
        val shot = PhoneAsset("s", takenAt = null, isVideo = false, addedAt = 9_000_000L, modifiedAt = 1_000L)
        val photo = PhoneAsset("p", takenAt = 5_000_000L, isVideo = false)
        val merged = Gallery.merge(listOf(shot, photo), emptyList())
        assertEquals(listOf("p", "s"), merged.map { it.id })
        assertEquals(1_000_000L, merged[1].date)
    }
}

class ScrubberTicksTest {
    private fun marks(vararg pairs: Pair<Int, Double>) = pairs.map { ScrubberMark(it.first, it.second) }

    @kotlin.test.Test fun aLibraryFrom2015ShowsBothEnds() {
        val m = marks(2026 to 0.0, 2025 to 0.12, 2024 to 0.25, 2023 to 0.4, 2020 to 0.55, 2016 to 0.8, 2015 to 0.93)
        val ticks = ScrubberTicks.make(m, 10)
        kotlin.test.assertEquals(2026, ticks.first().year)
        kotlin.test.assertEquals(2015, ticks.last().year)
        kotlin.test.assertEquals(7, ticks.size)
    }

    @kotlin.test.Test fun positionsComeFromTheLibraryNotFromEvenTime() {
        val ticks = ScrubberTicks.make(marks(2026 to 0.0, 2015 to 0.97), 10)
        kotlin.test.assertEquals(listOf(2026, 2015), ticks.map { it.year })
        kotlin.test.assertEquals(0.97, ticks[1].fraction)
    }

    @kotlin.test.Test fun monthsOfOneYearBecomeOneLabelAtTheFirst() {
        val ticks = ScrubberTicks.make(marks(2024 to 0.0, 2024 to 0.1, 2024 to 0.2, 2023 to 0.5), 10)
        kotlin.test.assertEquals(listOf(2024, 2023), ticks.map { it.year })
        kotlin.test.assertEquals(0.0, ticks[0].fraction)
    }

    @kotlin.test.Test fun crowdedLabelsAreThinnedWithoutLosingTheTop() {
        val m = (0 until 12).map { ScrubberMark(2026 - it, it / 12.0) }
        val ticks = ScrubberTicks.make(m, 5)
        kotlin.test.assertTrue(ticks.size <= 5)
        kotlin.test.assertEquals(2026, ticks.first().year)
        ticks.zipWithNext().forEach { (a, b) -> kotlin.test.assertTrue(b.fraction - a.fraction >= 0.2 - 1e-9) }
    }

    @kotlin.test.Test fun emptyAndSingleYearAreSafe() {
        kotlin.test.assertTrue(ScrubberTicks.make(emptyList(), 8).isEmpty())
        kotlin.test.assertEquals(listOf(2024), ScrubberTicks.make(marks(2024 to 0.0), 8).map { it.year })
        kotlin.test.assertTrue(ScrubberTicks.make(marks(2024 to 0.0), 0).isEmpty())
    }

    @kotlin.test.Test fun badFractionsAreIgnoredOrClamped() {
        val ticks = ScrubberTicks.make(marks(2024 to 0.0, 2023 to Double.NaN, 2022 to 1.4), 10)
        kotlin.test.assertEquals(listOf(2024, 2022), ticks.map { it.year })
        kotlin.test.assertTrue(ticks.all { it.fraction in 0.0..1.0 })
    }

    @kotlin.test.Test fun shortLibrariesGetNoMarks() {
        kotlin.test.assertFalse(ScrubberTicks.isLongEnough(3000.0, 800.0))
        kotlin.test.assertTrue(ScrubberTicks.isLongEnough(8000.0, 800.0))
        kotlin.test.assertFalse(ScrubberTicks.isLongEnough(8000.0, 0.0))
    }
}

class JumpToDateTest {
    private fun day(y: Int, m: Int): Long {
        val c = java.util.Calendar.getInstance()
        c.clear()
        c.set(y, m - 1, 15)
        return c.timeInMillis
    }

    @kotlin.test.Test fun emptyAndSingleStayAtTop() {
        kotlin.test.assertEquals(0.0, JumpToDate.fraction(day(2023, 3), longArrayOf()))
        kotlin.test.assertEquals(0.0, JumpToDate.fraction(day(2023, 3), longArrayOf(day(2024, 1))))
    }

    @kotlin.test.Test fun newestFirstMapsTargetToScrubberFraction() {
        val dates = longArrayOf(day(2024, 6), day(2023, 6), day(2022, 6), day(2021, 6))
        kotlin.test.assertEquals(0.0, JumpToDate.fraction(day(2024, 6), dates))
        kotlin.test.assertEquals(1.0 / 3, JumpToDate.fraction(day(2023, 6), dates), 1e-9)
        kotlin.test.assertEquals(1.0, JumpToDate.fraction(day(2021, 6), dates))
        kotlin.test.assertEquals(2.0 / 3, JumpToDate.fraction(day(2022, 12), dates), 1e-9)
    }

    @kotlin.test.Test fun olderThanLibraryGoesToBottom() {
        val dates = longArrayOf(day(2024, 1), day(2023, 1))
        kotlin.test.assertEquals(1.0, JumpToDate.fraction(day(2010, 1), dates))
    }

    @kotlin.test.Test fun yearRangeSpansLibraryAndToday() {
        val dates = longArrayOf(day(2020, 1), day(2018, 6))
        kotlin.test.assertEquals(2018..2024, JumpToDate.yearRange(dates, day(2024, 5)))
        kotlin.test.assertEquals(2024..2024, JumpToDate.yearRange(longArrayOf(), day(2024, 5)))
    }
}
