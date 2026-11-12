package app.lelvo.core.search

import app.lelvo.core.index.Gallery
import app.lelvo.core.index.ItemKind
import app.lelvo.core.index.ItemStatus
import app.lelvo.core.index.LibraryItem
import app.lelvo.core.index.PhoneAsset
import java.time.ZoneOffset
import java.util.Locale
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/** The iOS `SearchMatcherTests` and `SearchIndexTests`, case for case, plus what Android adds (folders, phone places). */
class SearchMatcherTest {
    @Test fun everyQueryWordMustStartAKnownWord() {
        val known = SearchMatcher.words("Beach sunset Kochi Kerala") + listOf("2023", "june")
        assertTrue(SearchMatcher.matches(SearchMatcher.words("sun"), known))
        assertTrue(SearchMatcher.matches(SearchMatcher.words("June 2023 beach"), known))
        assertFalse(SearchMatcher.matches(SearchMatcher.words("beach dog"), known))
        assertFalse(SearchMatcher.matches(SearchMatcher.words("each"), known))
        assertFalse(SearchMatcher.matches(emptyList(), known))
    }

    @Test fun accentsAndCaseDontMatter() {
        assertTrue(SearchMatcher.matches(SearchMatcher.words("CAFE"), SearchMatcher.words("Café de Flore")))
    }

    @Test fun datesAreFoundByYearAndMonth() {
        val date = 1_686_000_000_000L // 5 June 2023
        assertEquals(listOf("2023", "june"), SearchMatcher.dateWords(date, ZoneOffset.UTC, Locale.US))
        assertEquals(emptyList(), SearchMatcher.dateWords(null))
        assertEquals(listOf("2023", "june", "juin"), SearchMatcher.dateWords(date, ZoneOffset.UTC, Locale.FRANCE))
    }

    @Test fun videoLocationTags() {
        assertEquals(37.4219 to -122.084, SearchMatcher.parseIso6709("+37.4219-122.0840/"))
        assertEquals(9.9312 to 76.2673, SearchMatcher.parseIso6709("+09.9312+076.2673+012.000/"))
        assertEquals(null, SearchMatcher.parseIso6709("garbage"))
    }

    @Test fun nearbyPlacesShareACell() {
        assertEquals(SearchMatcher.placeCell(9.9312, 76.2673), SearchMatcher.placeCell(9.9298, 76.2701))
        assertNotEquals(SearchMatcher.placeCell(9.93, 76.26), SearchMatcher.placeCell(9.96, 76.26))
    }
}

class SearchIndexTest {
    private val index = SearchIndex(listOf(
        "a" to SearchMatcher.words("beach sunset Kochi 2023 june"),
        "b" to SearchMatcher.words("dog beach Goa 2024"),
        "c" to SearchMatcher.words("receipt cafe Kochi 2023"),
    ))

    @Test fun findsByPrefixInTimelineOrder() {
        assertEquals(listOf("a", "b"), index.search("bea"))
        assertEquals(listOf("a", "c"), index.search("Kochi 2023"))
        assertEquals(listOf("a"), index.search("kochi beach"))
        assertEquals(listOf("c"), index.search("café"))
    }

    @Test fun aWholeWordAlsoFindsWhatItIsCalled() {
        val index = SearchIndex(listOf(
            "a" to SearchMatcher.words("ocean people"),
            "b" to SearchMatcher.words("hill 2024"),
            "c" to SearchMatcher.words("bench"),
        ))
        assertEquals(listOf("a"), index.search("beach"))
        assertEquals(listOf("a"), index.search("sea"))
        assertEquals(listOf("a"), index.search("beach people"))
        assertEquals(emptyList(), index.search("beach 2024"))
        assertEquals(listOf("b"), index.search("mountains"))
        assertEquals(listOf("c"), index.search("be"), "A part of a word only finds words starting with it")
        assertTrue(SearchMatcher.matches(listOf("beach"), listOf("ocean")))
    }

    @Test fun missingWordsFindNothing() {
        assertEquals(emptyList(), index.search("cat"))
        assertEquals(emptyList(), index.search("beach cat"))
        assertEquals(emptyList(), index.search("  "))
        assertEquals(emptyList(), SearchIndex.empty.search("beach"))
    }

    /** The same answers as checking every entry's words. */
    @Test fun agreesWithMatcher() {
        val entries = (0 until 300).map { i -> "e$i" to SearchMatcher.words("w${i % 7} x${i % 11} year${2000 + i % 5}") }
        val index = SearchIndex(entries)
        for (q in listOf("w3", "x1 w2", "year2003", "w", "x10 year2001")) {
            val slow = entries.filter { SearchMatcher.matches(SearchMatcher.words(q), it.second) }.map { it.first }
            assertEquals(slow, index.search(q), q)
        }
    }
}

class SearchCorpusTest {
    private val june = 1_686_000_000_000L
    private val kochi = 9.9312 to 76.2673
    private val places = mapOf(SearchMatcher.placeCell(kochi.first, kochi.second) to "Kochi, Kerala, India")

    private fun item(id: String, at: Long, lat: Double? = null, lon: Double? = null, albums: List<String> = emptyList(), kind: ItemKind = ItemKind.Photo) =
        LibraryItem(id = id, localId = null, sha256 = "h", filename = "IMG_$id.HEIC", kind = kind, createdAt = at, fileSize = 1,
            status = ItemStatus.BackedUp, latitude = lat, longitude = lon, albums = albums)

    private val entries = Gallery.merge(
        assets = listOf(
            PhoneAsset("p1", june + 3, false, filename = "Screenshot_1.png", bucketName = "Screenshots"),
            PhoneAsset("p2", june + 2, true, filename = "VID_2.mp4", bucketName = "WhatsApp Video", isFavorite = true),
        ),
        items = listOf(item("c1", june + 1, kochi.first, kochi.second, albums = listOf("Holiday")), item("c0", june, 0.0, 0.0)),
    )
    private val phone = mapOf("p2" to kochi)

    @Test fun findsByPlaceDateKindFolderAlbumAndName() {
        val index = SearchCorpus.index(entries, places, phone::get, ZoneOffset.UTC, Locale.US)
        assertEquals(listOf("p2", "cloud-c1"), index.search("kochi"), "the phone file's place and the backup's place")
        assertEquals(listOf("p2", "cloud-c1"), index.search("kerala june 2023"))
        assertEquals(listOf("p1"), index.search("screenshots"))
        assertEquals(listOf("p2"), index.search("whatsapp"))
        assertEquals(listOf("p2"), index.search("videos"))
        assertEquals(listOf("p2"), index.search("favorites"))
        assertEquals(listOf("cloud-c1"), index.search("holiday"))
        assertEquals(listOf("cloud-c0"), index.search("img_c0"))
    }

    @Test fun zeroZeroIsNoPlace() {
        assertEquals(null, SearchCorpus.cell(entries.last(), phone::get))
    }

    @Test fun suggestionsCountPlacesByCityWithTheNewestAsCover() {
        val s = SearchCorpus.suggestions(entries, places, phone::get, zone = ZoneOffset.UTC, locale = Locale.US)
        assertEquals(listOf(SearchCorpus.Place("Kochi", 2, "p2")), s.places)
        assertEquals(listOf("June 2023"), s.months)
    }
}
