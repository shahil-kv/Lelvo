package app.lelvo.core.memories

import java.time.LocalDateTime
import java.time.ZoneOffset
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The iOS `MemoriesTests`, case for case: both apps must make the same memories from the same library. */
class MemoriesTest {
    private val zone = ZoneOffset.UTC
    private val dayMs = 86_400_000L
    private val hourMs = 3_600_000L

    private fun day(y: Int, m: Int, d: Int, hour: Int = 12, minute: Int = 0) =
        LocalDateTime.of(y, m, d, hour, minute).toInstant(zone).toEpochMilli()

    private val home = 9.93 to 76.26
    private val work = 10.02 to 76.31
    private val away = 15.49 to 73.82

    private fun at(id: String, date: Long, place: Pair<Double, Double>?) = Memories.Photo(id, date, place?.first, place?.second)

    private val everyday: List<Memories.Photo>
        get() = (0 until 120).flatMap { d ->
            val date = day(2025, 1, 1) + d * dayMs
            listOf(at("h$d", date, home), at("w$d", date + hourMs, work))
        }

    @Test fun onThisDayGroupsEarlierYearsMostRecentFirst() {
        val photos = listOf(
            Memories.Photo("a", day(2023, 10, 28)), Memories.Photo("b", day(2023, 10, 28, 18)), Memories.Photo("b2", day(2023, 10, 28, 20)),
            Memories.Photo("c", day(2021, 10, 28)), Memories.Photo("d", day(2021, 10, 28, 9)), Memories.Photo("d2", day(2021, 10, 28, 7)),
            Memories.Photo("e", day(2022, 10, 28)),
            Memories.Photo("f", day(2026, 10, 28)), Memories.Photo("g", day(2026, 10, 28)),
        )
        val found = Memories.onThisDay(photos, day(2026, 10, 28), zone)
        assertEquals(listOf<Memories.Kind>(Memories.Kind.OnThisDay(3), Memories.Kind.OnThisDay(5)), found.map { it.kind })
        assertEquals(listOf("a", "b", "b2"), found[0].allIds)
        assertEquals(listOf("d2", "d", "c"), found[1].allIds)
    }

    @Test fun homeAndWorkAreBothBases() {
        assertEquals(2, Memories.bases(everyday, zone).size)
        val week = (0 until 200).map { at("x$it", day(2025, 5, 1) + it * 3_000_000L, away) }
        assertEquals(2, Memories.bases(everyday + week, zone).size)
    }

    @Test fun aFewDaysFarFromEveryBaseIsATrip() {
        val photos = everyday + (0 until 30).map { at("t$it", day(2025, 6, 10) + it * 4 * hourMs, away) } +
            at("noloc", day(2025, 6, 11, 1), null) + at("back", day(2025, 6, 16), home)
        val trips = Memories.trips(photos, zone)
        assertEquals(1, trips.size)
        assertEquals(31, trips[0].allIds.size)
        assertTrue("noloc" in trips[0].allIds)
        assertEquals(Memories.STORY_LENGTH, trips[0].ids.size)
        assertEquals(Memories.placeCell(away.first, away.second), trips[0].placeCell)
    }

    @Test fun goingToWorkOrADayOutIsNotATrip() {
        val photos = everyday + (0 until 40).map { at("o$it", day(2025, 2, 20, 8) + it * 10 * 60_000L, away) } +
            (0 until 10).map { at("s$it", day(2025, 4, 1) + it * dayMs / 3, away) }
        assertTrue(Memories.trips(photos, zone).isEmpty())
    }

    @Test fun noBasesMeansNoTrips() {
        assertTrue(Memories.trips((0 until 40).map { at("t$it", day(2025, 3, 10) + it * hourMs, away) }, zone).isEmpty())
    }

    @Test fun selectionIsSpreadOutAndSkipsBursts() {
        val burst = (0 until 100).map { Memories.Photo("b$it", day(2025, 1, 1) + it * 1000L) }
        val spread = (0 until 100).map { Memories.Photo("s$it", day(2025, 1, 2) + it * hourMs) }
        assertEquals(1, Memories.select(burst).size)
        val picked = Memories.select(spread)
        assertEquals(Memories.STORY_LENGTH, picked.size)
        assertEquals("s0", picked.first().id)
        assertEquals(5, Memories.select(spread.take(5)).size)
    }

    @Test fun themesNeedEnoughPhotosOnEnoughDays() {
        val dogs = (0 until 15).map { Memories.Photo("d$it", day(2025, 6, 1 + it % 5, 9 + it), things = listOf("dog", "grass")) }
        val snowOneDay = (0 until 20).map { Memories.Photo("s$it", day(2025, 1, 5, 8, it), things = listOf("snow")) }
        val themes = Memories.themes(dogs + snowOneDay, zone)
        assertEquals(listOf<Memories.Kind>(Memories.Kind.Theme(Memories.Theme.Dogs)), themes.map { it.kind })
        assertEquals(15, themes[0].allIds.size)
    }

    @Test fun recentHighlightsAreTheLastMonth() {
        val today = day(2026, 10, 28)
        val recent = (0 until 14).map { Memories.Photo("r$it", today - it * dayMs) }
        val old = (0 until 30).map { Memories.Photo("o$it", day(2025, 1, 1) + it * dayMs) }
        assertEquals(14, Memories.recent(recent + old, today, zone)?.allIds?.size)
        assertNull(Memories.recent(old, today, zone))
    }

    @Test fun bestLookingPhotosArePickedAndCoverIt() {
        val photos = (0 until 40).map { Memories.Photo("p$it", day(2025, 1, 1) + it * hourMs, score = if (it % 2 == 1) 0.5 else -0.5) }
        val picked = Memories.select(photos)
        assertEquals(20, picked.size)
        assertTrue(picked.all { it.score == 0.5 })
        val best = Memories.Photo("best", day(2025, 3, 1), score = 0.9)
        assertNull(Memories.recent(photos.take(12) + best, day(2025, 3, 2), zone))
        val moved = photos.map { Memories.Photo(it.id, day(2025, 2, 20) + it.id.drop(1).toLong() * hourMs, score = it.score) }
        val all = Memories.all(moved + best, day(2025, 3, 2), zone)
        assertEquals(Memories.Kind.Recent, all.first().kind)
        assertEquals("best", all.first().cover)
    }

    @Test fun screenshotsAndDocumentsNeverMakeAMemory() {
        val today = day(2026, 10, 28)
        assertTrue(Memories.all((0 until 20).map { Memories.Photo("x$it", today - it * dayMs, isUtility = true) }, today, zone).isEmpty())
    }

    @Test fun aLongStayAbroadIsOneMemory() {
        val dubai = 25.2 to 55.27
        var photos = (0 until 100).flatMap { d -> if (d >= 99) emptyList() else listOf(at("h$d", day(2024, 2, 1) + d * dayMs, home)) }
        photos = photos.filter { it.date < day(2024, 5, 9) } + photos.filter { it.date > day(2024, 6, 29) }
        photos = photos + (100 until 220).map { d -> at("h$d", day(2024, 2, 1) + d * dayMs, home) }.filter { it.date > day(2024, 6, 29) }
        val days = listOf(Triple(5, 10, 3), Triple(5, 15, 1), Triple(5, 17, 6), Triple(5, 19, 5), Triple(5, 23, 11), Triple(6, 9, 4), Triple(6, 15, 2), Triple(6, 16, 13), Triple(6, 19, 2), Triple(6, 27, 1))
        for ((m, d, n) in days) photos = photos + (0 until n).map { i -> at("d$m-$d-$i", day(2024, m, d, 9 + i % 12, i), dubai) }
        assertEquals(1, Memories.bases(photos, zone).size)
        val trips = Memories.trips(photos, zone)
        assertEquals(1, trips.size)
        assertEquals(48, trips[0].allIds.size)
        assertTrue(trips[0].placeCell!!.startsWith("25."))
    }

    @Test fun nearbyOutingsWeeksApartAreSeparate() {
        val dayOut = home.first + 0.3 to home.second + 0.2
        val hills = home.first + 1.5 to home.second + 0.4
        val photos = everyday + (0 until 9).map { at("o$it", day(2025, 6, 10, 9 + it), dayOut) } +
            (0 until 30).map { at("t$it", day(2025, 6, 23) + it * 3 * hourMs, hills) }
        val trips = Memories.trips(photos, zone)
        assertEquals(1, trips.size)
        assertTrue(trips[0].allIds.all { it.startsWith("t") })
    }

    @Test fun aRoadTripThroughSeveralTownsIsOneTrip() {
        val towns = listOf(12.97 to 77.59, 12.30 to 76.64, 11.41 to 76.70, 10.09 to 77.06)
        val photos = everyday + towns.flatMapIndexed { t, town -> (0 until 8).map { i -> at("r$t-$i", day(2025, 6, 10 + t, 8 + i), town) } }
        val trips = Memories.trips(photos, zone)
        assertEquals(1, trips.size)
        assertEquals(32, trips[0].allIds.size)
    }

    @Test fun differentPlacesWeeksApartAreTwoTrips() {
        val photos = everyday + (0 until 25).map { at("a$it", day(2025, 6, 10) + it * 4 * hourMs, 15.49 to 73.82) } +
            (0 until 25).map { at("b$it", day(2025, 7, 1) + it * 4 * hourMs, 13.75 to 100.50) }
        val trips = Memories.trips(photos, zone)
        assertEquals(2, trips.size)
        assertEquals(setOf("a", "b"), trips.map { it.allIds.first().take(1) }.toSet())
    }

    @Test fun aLongHolidayIsNotAHome() {
        val holiday = (0 until 60).map { at("x$it", day(2025, 8, 1) + it * dayMs, 41.39 to 2.17) }
        assertEquals(2, Memories.bases(everyday + holiday, zone).size)
        val trips = Memories.trips(everyday + holiday, zone)
        assertEquals(1, trips.size)
        assertEquals(60, trips[0].allIds.size)
    }

    @Test fun placeCellMatchesIos() {
        assertEquals("9.93,76.26", Memories.placeCell(9.9312, 76.2649))
        assertEquals("-33.87,151.21", Memories.placeCell(-33.8688, 151.2093))
        assertEquals("0.13,-0.13", Memories.placeCell(0.125, -0.125))
    }
}

class MemoryCardsTest {
    private val zone = java.time.ZoneOffset.UTC
    private val day = 86_400_000L
    private fun m(kind: Memories.Kind, start: Long, end: Long, cell: String? = null) = Memories.Memory(kind, listOf("a"), listOf("a", "b"), start, end, "a", cell)
    private val nov1 = java.time.LocalDate.of(2025, 11, 1).atStartOfDay(zone).toInstant().toEpochMilli()

    @Test fun titlesReadLikeIos() {
        val cards = MemoryCards.of(
            listOf(
                m(Memories.Kind.OnThisDay(1), nov1, nov1, "15.49,73.82"),
                m(Memories.Kind.OnThisDay(3), nov1, nov1),
                m(Memories.Kind.Recent, nov1, nov1 + 40 * day),
                m(Memories.Kind.Trip, nov1, nov1 + 2 * day, "15.49,73.82"),
                m(Memories.Kind.Trip, nov1, nov1 + 40 * day),
                m(Memories.Kind.Theme(Memories.Theme.Dogs), nov1, nov1),
            ),
            zone, java.util.Locale.UK, placeName = { if (it == "15.49,73.82") "Goa" else null },
        )
        assertEquals(listOf("One Year Ago", "3 Years Ago", "Recent Highlights", "Trip to Goa", "Away, November 2025 – December 2025", "Dogs"), cards.map { it.title })
        assertEquals("1 November 2025 · Goa", cards[0].subtitle)
        assertEquals("November 2025 · 3 days", cards[3].subtitle)
        assertEquals("November 2025 – December 2025 · 41 days", cards[4].subtitle)
        assertEquals("2 photos · November 2025", cards[5].subtitle)
    }
}
