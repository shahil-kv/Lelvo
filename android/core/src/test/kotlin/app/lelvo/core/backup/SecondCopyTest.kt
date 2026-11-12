package app.lelvo.core.backup

import app.lelvo.core.index.ItemKind
import app.lelvo.core.index.ItemStatus
import app.lelvo.core.index.LibraryItem
import app.lelvo.core.index.RemoteFile
import java.time.ZoneOffset
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** iOS `SecondCopyTests`. */
class SecondCopyTest {
    private val utc = ZoneOffset.UTC
    private val may = 1_715_342_400_000L

    private fun item(id: String, name: String = "IMG_0001.HEIC", size: Long = 100, kind: ItemKind = ItemKind.Photo, date: Long? = may, roles: List<String> = listOf("o")): LibraryItem {
        var m = LibraryItem(id, null, "h-$id", name, kind, date, fileSize = size, status = ItemStatus.BackedUp)
        roles.forEachIndexed { i, r -> m = m.withParts(r, listOf(RemoteFile(i + 1L, "f$i", "u$i", size)), 1) }
        return m
    }

    private fun plan(items: List<LibraryItem>, m: SecondCopy.Manifest = SecondCopy.Manifest(), disk: Map<String, Long> = emptyMap()) =
        SecondCopy.plan(items, m, utc) { disk[it] }

    private fun manifest(vararg e: Pair<String, SecondCopy.Entry>) = SecondCopy.Manifest(mapOf(*e))

    @Test fun emptyFolderCopiesEverythingIntoYearAndMonth() {
        val p = plan(listOf(item("aaaaaaaa1")))
        assertEquals(listOf("2024/05/IMG_0001.HEIC"), p.toCopy.map { it.path })
        assertEquals("o", p.toCopy.first().role)
        assertEquals(100, p.bytesToCopy)
        assertTrue(p.upToDate == 0 && p.toAdopt.isEmpty())
    }

    @Test fun livePhotoAndEditAddTheirOwnFiles() {
        val live = item("aaaaaaaa1", kind = ItemKind.LivePhoto, roles = listOf("o", "pv", "e"))
            .copy(pairedVideoSize = 40, hasEdit = true, editedName = "FullSizeRender.jpg", editedSize = 90)
        val files = SecondCopy.wanted(live, utc)
        assertEquals(listOf("2024/05/IMG_0001.HEIC", "2024/05/IMG_0001.MOV", "2024/05/IMG_0001 (edited).jpg"), files.map { it.path })
        assertEquals(listOf(100L, 40L, 90L), files.map { it.size })
    }

    @Test fun copiedFilesWithTheRightSizeAreNotCopiedAgain() {
        val p = plan(listOf(item("aaaaaaaa1")), manifest("aaaaaaaa1/o" to SecondCopy.Entry("2024/05/IMG_0001.HEIC", 100)), mapOf("2024/05/IMG_0001.HEIC" to 100L))
        assertTrue(p.toCopy.isEmpty()); assertEquals(1, p.upToDate); assertEquals(100, p.upToDateBytes)
    }

    @Test fun missingFilesAreCopiedAgainToTheSamePath() {
        val p = plan(listOf(item("aaaaaaaa1")), manifest("aaaaaaaa1/o" to SecondCopy.Entry("2024/05/IMG_0001-aaaaaa.HEIC", 100)))
        assertEquals(listOf("2024/05/IMG_0001-aaaaaa.HEIC"), p.toCopy.map { it.path })
    }

    @Test fun aFileChangedOutsideLelvoIsKeptAndTheCopyGoesToANewPath() {
        val p = plan(listOf(item("aaaaaaaa1")), manifest("aaaaaaaa1/o" to SecondCopy.Entry("2024/05/IMG_0001.HEIC", 100)), mapOf("2024/05/IMG_0001.HEIC" to 37L))
        assertEquals(listOf("2024/05/IMG_0001-aaaaaa.HEIC"), p.toCopy.map { it.path })
        assertEquals(0, p.upToDate)
    }

    @Test fun aManifestPathThatLeavesTheFolderIsNeverPlanned() {
        for (bad in listOf("../../Documents/x.pages", "/etc/passwd", "2024/../../x", "./x", "2024//x", "~/x", "a\\b", "")) {
            assertFalse(SecondCopy.isSafe(bad), bad)
            val p = plan(listOf(item("aaaaaaaa1")), manifest("aaaaaaaa1/o" to SecondCopy.Entry(bad, 100)), mapOf(bad to 100L))
            assertEquals(listOf("2024/05/IMG_0001.HEIC"), p.toCopy.map { it.path }, bad)
            assertTrue(p.upToDate == 0 && p.toAdopt.isEmpty())
        }
    }

    @Test fun ordinaryPathsAreSafe() {
        assertTrue(SecondCopy.isSafe("2024/05/IMG_0001 (edited).jpg"))
        assertTrue(SecondCopy.isSafe("2024/05/..hidden..jpg"))
    }

    @Test fun sameNameAndSizeFromTwoItemsNeverShareAFile() {
        val p = plan(listOf(item("aaaaaaaa1"), item("bbbbbbbb2")))
        assertEquals(setOf("2024/05/IMG_0001.HEIC", "2024/05/IMG_0001-bbbbbb.HEIC"), p.toCopy.map { it.path }.toSet())
    }

    @Test fun aPathOwnedByAnotherItemInTheManifestIsNotTaken() {
        val p = plan(listOf(item("bbbbbbbb2")), manifest("aaaaaaaa1/o" to SecondCopy.Entry("2024/05/img_0001.heic", 100)), mapOf("2024/05/img_0001.heic" to 100L))
        assertEquals(listOf("2024/05/IMG_0001-bbbbbb.HEIC"), p.toCopy.map { it.path })
        assertEquals(1, p.removedFromLibrary)
    }

    @Test fun filesAlreadyThereWithTheRightSizeAreAdopted() {
        val p = plan(listOf(item("aaaaaaaa1")), disk = mapOf("2024/05/IMG_0001.HEIC" to 100L))
        assertEquals(listOf("2024/05/IMG_0001.HEIC"), p.toAdopt.map { it.path })
        assertTrue(p.toCopy.isEmpty())
    }

    @Test fun aDifferentFileAtThePathIsLeftAlone() {
        val p = plan(listOf(item("aaaaaaaa1")), disk = mapOf("2024/05/IMG_0001.HEIC" to 55L))
        assertEquals(listOf("2024/05/IMG_0001-aaaaaa.HEIC"), p.toCopy.map { it.path })
        assertTrue(p.toAdopt.isEmpty())
    }

    @Test fun removedItemsAreCountedButNeverPlannedForDeletion() {
        val p = plan(emptyList(), manifest("gone0001/o" to SecondCopy.Entry("2023/01/OLD.JPG", 10), "gone0001/pv" to SecondCopy.Entry("2023/01/OLD.MOV", 10)))
        assertEquals(1, p.removedFromLibrary)
        assertTrue(p.toCopy.isEmpty() && p.toAdopt.isEmpty())
    }

    @Test fun manifestRoundTripsAndRecords() {
        val m = SecondCopy.Manifest().record(SecondCopy.File("aaaaaaaa1", "pv", "2024/05/A.MOV", 0, null), 42)
        val back = SecondCopy.Manifest.decode(m.encode())
        assertEquals(m, back)
        assertEquals(SecondCopy.Entry("2024/05/A.MOV", 42), back.files["aaaaaaaa1/pv"])
        assertEquals(setOf("aaaaaaaa1"), back.itemIds)
        // The Mac's JSON (Swift's Codable) reads the same.
        assertEquals(back, SecondCopy.Manifest.decode("""{"version":1,"files":{"aaaaaaaa1/pv":{"path":"2024\/05\/A.MOV","size":42}}}"""))
        assertEquals(SecondCopy.Manifest(), SecondCopy.Manifest.decode("not json"))
    }

    @Test fun namesAreSafeOnEveryDrive() {
        assertEquals("a_b_c_.jpg", SecondCopy.sanitized("a/b:c?.jpg"))
        assertEquals("_hidden.jpg", SecondCopy.sanitized(".hidden.jpg"))
        assertEquals("file", SecondCopy.sanitized("  "))
    }

    @Test fun undatedItemsGoInto1970() {
        assertEquals("1970/01/IMG_0001.HEIC", SecondCopy.wanted(item("aaaaaaaa1", date = null), utc).first().path)
    }
}
