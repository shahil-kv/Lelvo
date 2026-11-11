package app.lelvo.core.index

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

// Mirrors RestoreLinkerTests in Packages/LelvoCore/Tests (BackupLogicTests.swift).
class RestoreLinkerTest {
    private val date = 1_790_000_000_000L
    private var n = 0

    private fun cloud(name: String, at: Long?, w: Int = 4032, h: Int = 3024, source: String? = null) = LibraryItem(
        id = "item-${n++}", localId = null, sha256 = "h", filename = name, kind = ItemKind.Photo, createdAt = at,
        width = w, height = h, fileSize = 1, status = ItemStatus.BackedUp, sourceLocalId = source,
    )

    @Test fun linksByUploadedAssetIdFirst() {
        val item = cloud("IMG_1.HEIC", date, source = "1001")
        // Renamed or edited on the phone since: only the id still matches.
        val assets = listOf(AssetKey("1001", "IMG_1 (edited).HEIC", date, 100, 100))
        assertEquals(mapOf(item.id to "1001"), RestoreLinker.match(listOf(item), assets))
    }

    @Test fun fallsBackToNameSecondAndSize() {
        val item = cloud("IMG_2.HEIC", date)
        val assets = listOf(AssetKey("B", "img_2.heic", date + 400, 4032, 3024), AssetKey("C", "IMG_2.HEIC", date + 1000, 4032, 3024))
        assertEquals(mapOf(item.id to "B"), RestoreLinker.match(listOf(item), assets))
    }

    @Test fun differentSizeOrMissingDateDoesNotMatch() {
        val a = cloud("IMG_3.HEIC", date)
        val b = cloud("IMG_4.HEIC", null)
        val assets = listOf(AssetKey("D", "IMG_3.HEIC", date, 3024, 4032), AssetKey("E", "IMG_4.HEIC", null, 4032, 3024))
        assertTrue(RestoreLinker.match(listOf(a, b), assets).isEmpty())
    }

    @Test fun eachAssetLinksOnce() {
        val links = RestoreLinker.match(listOf(cloud("IMG_5.HEIC", date), cloud("IMG_5.HEIC", date)), listOf(AssetKey("F", "IMG_5.HEIC", date, 4032, 3024)))
        assertEquals(1, links.size)
        assertEquals(setOf("F"), links.values.toSet())
    }
}
