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

    @Test fun notBackedUpFilter() {
        assertTrue(GalleryFilter.NotBackedUp.matches(GalleryEntry("p", 1, asset("p", 1), null)))
        assertTrue(!GalleryFilter.NotBackedUp.matches(GalleryEntry("cloud-c", 1, null, item("c", 1))))
    }
}
