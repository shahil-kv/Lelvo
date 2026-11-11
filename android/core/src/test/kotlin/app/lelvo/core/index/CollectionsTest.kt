package app.lelvo.core.index

import java.time.LocalDate
import java.time.ZoneOffset
import kotlin.test.Test
import kotlin.test.assertEquals

class CollectionsTest {
    private val zone = ZoneOffset.UTC
    private val today = LocalDate.of(2026, 11, 11)
    private fun at(day: LocalDate, hour: Int = 12) = day.atTime(hour, 0).toInstant(zone).toEpochMilli()

    private fun cloud(id: String, at: Long, albums: List<String> = emptyList(), fav: Boolean = false, kind: ItemKind = ItemKind.Photo) =
        GalleryEntry(
            "cloud-$id", at, null,
            LibraryItem(id, null, "h", "$id.jpg", kind, at, fileSize = 1, status = ItemStatus.BackedUp, favorite = fav, albums = albums),
        )

    private fun phone(id: String, at: Long, bucket: String, name: String, video: Boolean = false) =
        GalleryEntry(id, at, PhoneAsset(id, at, video, bucketId = bucket, bucketName = name), null)

    private fun build(entries: List<GalleryEntry>, dayCount: Int = 10) =
        Collections.build(entries, zone, today, { it.toString() }, dayCount)

    @Test fun recentDaysNameTodayAndYesterdayAndStopAtTheLimit() {
        val c = build(
            listOf(
                cloud("a", at(today, 15)), cloud("b", at(today, 9)), cloud("c", at(today.minusDays(1))),
                cloud("d", at(today.minusDays(5))), cloud("e", at(today.minusDays(9))),
            ),
            dayCount = 3,
        )
        assertEquals(listOf("Today", "Yesterday", "2026-11-06"), c.days.map { it.filter.title })
        assertEquals(listOf(2, 1, 1), c.days.map { it.count })
        assertEquals("cloud-a", c.days[0].cover?.id)
        assertEquals(setOf("cloud-a", "cloud-b"), (c.days[0].filter as GalleryFilter.Matching).ids)
    }

    @Test fun favoritesFirstThenAlbumsByName() {
        val c = build(
            listOf(cloud("a", 3, listOf("trip", "Birthday")), cloud("b", 2, listOf("Trip")), cloud("c", 1, fav = true)),
        )
        assertEquals(listOf("Favorites", "Birthday", "Trip", "trip"), c.albums.map { it.filter.title })
        assertEquals(GalleryFilter.Album("trip"), c.albums[3].filter)
    }

    @Test fun cameraAndScreenshotsLeadTheFoldersThenNewest() {
        val c = build(
            listOf(
                phone("1", 50, "w", "WhatsApp Images"), phone("2", 40, "d", "Download"),
                phone("3", 30, "s", "Screenshots"), phone("4", 20, "c", "Camera"), phone("5", 10, "c", "Camera"),
            ),
        )
        assertEquals(listOf("Camera", "Screenshots", "WhatsApp Images", "Download"), c.folders.map { it.filter.title })
        assertEquals(2, c.folders[0].count)
        assertEquals("4", c.folders[0].cover?.id)
    }

    @Test fun mediaTypesOnlyWhenThereAreSome() {
        val c = build(listOf(cloud("a", 2, kind = ItemKind.Video), phone("p", 1, "c", "Camera")))
        assertEquals(listOf("Videos", "Only in the cloud", "Not backed up"), c.media.map { it.filter.title })
    }

    @Test fun filtersMatchAlbumsFoldersAndSets() {
        val e = cloud("a", 1, listOf("Trip"))
        val p = phone("p", 1, "c", "Camera")
        assertEquals(true, GalleryFilter.Album("Trip").matches(e))
        assertEquals(false, GalleryFilter.Album("trip").matches(e))
        assertEquals(true, GalleryFilter.Folder("Camera", "c").matches(p))
        assertEquals(false, GalleryFilter.Folder("Camera", "c").matches(e))
        assertEquals(true, GalleryFilter.Matching("x", setOf("p")).matches(p))
    }
}
