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
