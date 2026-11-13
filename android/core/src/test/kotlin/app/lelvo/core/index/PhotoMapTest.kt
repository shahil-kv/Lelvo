package app.lelvo.core.index

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class PhotoMapTest {
    private fun item(id: String, at: Long, lat: Double?, lon: Double?) = LibraryItem(
        id = id, localId = null, sha256 = "h", filename = "$id.jpg", kind = ItemKind.Photo, createdAt = at, fileSize = 1,
        status = ItemStatus.BackedUp, latitude = lat, longitude = lon,
    )

    @Test fun phoneLocationFirstThenTheBackupsAndZerosAreMissing() {
        val entries = listOf(
            GalleryEntry("p1", 10, PhoneAsset("p1", 10, false), null),
            GalleryEntry("cloud-c1", 20, null, item("c1", 20, 12.97, 77.59)),
            GalleryEntry("cloud-c2", 30, null, item("c2", 30, 0.0, 0.0)),
            GalleryEntry("cloud-c3", 40, null, item("c3", 40, null, null)),
            GalleryEntry("p2", 50, PhoneAsset("p2", 50, false), null),
        )
        val pins = PhotoMap.pins(entries) { id -> if (id == "p1") 48.85 to 2.35 else null }
        assertEquals(listOf("p1", "cloud-c1"), pins.map { it.id })
        assertEquals(48.85, pins[0].lat)
    }

    @Test fun nearbyPinsGroupUnderTheNewestAndOffScreenOnesAreLeftOut() {
        val pins = listOf(
            MapPin("a", 1.0, 1.0, 100), MapPin("b", 1.0, 1.0, 300), MapPin("c", 1.0, 1.0, 200),
            MapPin("far", 2.0, 2.0, 50), MapPin("gone", 3.0, 3.0, 400),
        )
        val screen = mapOf("a" to (10f to 10f), "b" to (40f to 30f), "c" to (60f to 60f), "far" to (500f to 500f))
        val clusters = PhotoMap.cluster(pins, 64f) { screen[it.id] }
        assertEquals(2, clusters.size)
        assertEquals("b", clusters[0].cover.id)
        assertEquals(listOf("b", "c", "a"), clusters[0].ids)
        assertEquals(1, clusters[1].count)
    }

    @Test fun negativeScreenPositionsDontShareACellWithPositiveOnes() {
        val pins = listOf(MapPin("left", 1.0, 1.0, 1), MapPin("right", 1.0, 1.0, 2))
        val clusters = PhotoMap.cluster(pins, 64f) { if (it.id == "left") -10f to 5f else 10f to 5f }
        assertEquals(2, clusters.size)
    }

    @Test fun boundsCoverEveryPin() {
        assertNull(PhotoMap.bounds(emptyList()))
        val b = PhotoMap.bounds(listOf(MapPin("a", 10.0, -5.0, 0), MapPin("b", -3.0, 20.0, 0)))
        assertEquals((-3.0 to -5.0) to (10.0 to 20.0), b)
    }
}
