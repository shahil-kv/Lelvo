package app.lelvo.core.index

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/** What the timeline shows and how it's split into sections (iOS `GalleryModel.merge` and `group`). */
object Timeline {
    enum class Grouping { Day, Month, Year }

    /** A section title; the app turns it into localized text. */
    sealed interface Title {
        data object Today : Title
        data object Yesterday : Title
        data class Day(val date: LocalDate) : Title
        data class Month(val year: Int, val month: Int) : Title
        data class Year(val year: Int) : Title
        data object Unknown : Title
    }

    data class Section<T>(val key: String, val title: Title, val items: List<T>)

    /**
     * Backed-up items only: hidden ones never show (they're in the backup and come back hidden), and trashed or
     * unfinished ones aren't in the library yet. Newest first; items without a date at the end.
     */
    fun visible(items: List<LibraryItem>): List<LibraryItem> = items
        .filter { it.status == ItemStatus.BackedUp && !it.hidden }
        .sortedWith(compareBy<LibraryItem> { it.createdAt == null }.thenByDescending { it.createdAt ?: 0 }.thenBy { it.id })

    /** Splits sorted [items] into sections. Days are counted in [zone], the phone's time zone. */
    fun group(items: List<LibraryItem>, grouping: Grouping, zone: ZoneId, today: LocalDate): List<Section<LibraryItem>> =
        group(items, { it.createdAt }, grouping, zone, today)

    /** Timeline tiles (phone photos and cloud items) into sections. */
    fun groupEntries(entries: List<GalleryEntry>, grouping: Grouping, zone: ZoneId, today: LocalDate): List<Section<GalleryEntry>> =
        group(entries, { it.date }, grouping, zone, today)

    fun <T> group(items: List<T>, dateOf: (T) -> Long?, grouping: Grouping, zone: ZoneId, today: LocalDate): List<Section<T>> {
        val sections = mutableListOf<Section<T>>()
        var key: String? = null
        var title: Title = Title.Unknown
        var bucket = mutableListOf<T>()
        for (item in items) {
            val date = dateOf(item)?.let { Instant.ofEpochMilli(it).atZone(zone).toLocalDate() }
            val k: String
            val t: Title
            when {
                date == null -> { k = "unknown"; t = Title.Unknown }
                grouping == Grouping.Day -> {
                    k = date.toString()
                    t = when (date) {
                        today -> Title.Today
                        today.minusDays(1) -> Title.Yesterday
                        else -> Title.Day(date)
                    }
                }
                grouping == Grouping.Month -> { k = "${date.year}-${date.monthValue}"; t = Title.Month(date.year, date.monthValue) }
                else -> { k = "${date.year}"; t = Title.Year(date.year) }
            }
            if (k != key) {
                key?.let { if (bucket.isNotEmpty()) sections += Section(it, title, bucket) }
                key = k; title = t; bucket = mutableListOf()
            }
            bucket += item
        }
        key?.let { if (bucket.isNotEmpty()) sections += Section(it, title, bucket) }
        // Undated items can form several runs; section keys stay unique for the grid (iOS does the same).
        val seen = HashSet<String>()
        return sections.map { s ->
            var k = s.key
            var n = 1
            while (!seen.add(k)) { n++; k = "${s.key}#$n" }
            if (k == s.key) s else s.copy(key = k)
        }
    }
}
