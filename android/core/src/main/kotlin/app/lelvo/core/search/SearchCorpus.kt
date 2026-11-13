package app.lelvo.core.search

import app.lelvo.core.index.GalleryEntry
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * What each timeline entry is found by, and the suggestions under an empty field (iOS `SearchService.index` and
 * `suggestions`). Things in photos come from the phone's labeller; text in photos isn't read on Android yet.
 */
object SearchCorpus {
    /** A photo's location: the phone file's (read by the app) or the backup's. */
    fun location(e: GalleryEntry, phone: (String) -> Pair<Double, Double>?): Pair<Double, Double>? {
        e.asset?.let { a -> phone(a.localId)?.let { return it } }
        val item = e.item ?: return null
        val lat = item.latitude ?: return null
        val lon = item.longitude ?: return null
        return if (lat == 0.0 && lon == 0.0) null else lat to lon
    }

    fun cell(e: GalleryEntry, phone: (String) -> Pair<Double, Double>?): String? =
        location(e, phone)?.let { (lat, lon) -> SearchMatcher.placeCell(lat, lon) }

    /**
     * The inverted index of every entry's words, in timeline order. [places]: cell → "City, State, Country".
     * [things]: what is in the photo ("christmas_tree"), stored as words the way iOS does (`storedWords`).
     */
    fun index(
        entries: List<GalleryEntry>, places: Map<String, String>, phone: (String) -> Pair<Double, Double>?,
        zone: ZoneId = ZoneId.systemDefault(), locale: Locale = Locale.getDefault(),
        things: (GalleryEntry) -> List<String> = { emptyList() },
    ): SearchIndex = SearchIndex(entries.map { e ->
        val known = SearchMatcher.dateWords(e.date, zone, locale).toMutableList()
        known += SearchMatcher.words(things(e).joinToString(" ") { it.replace('_', ' ') })
        cell(e, phone)?.let { places[it] }?.let { known += SearchMatcher.words(it) }
        e.item?.let { known += SearchMatcher.words((it.albums + it.filename).joinToString(" ")) }
        // Android's own albums are folders: "whatsapp", "camera", "screenshots" find their photos.
        e.asset?.let { known += SearchMatcher.words(listOfNotNull(it.filename, it.bucketName).joinToString(" ")) }
        known += kindWords(e)
        e.id to known
    })

    fun kindWords(e: GalleryEntry): List<String> = buildList {
        if (e.isVideo) addAll(listOf("video", "videos"))
        if (e.isLive) addAll(listOf("live", "photo"))
        if (!e.isVideo) addAll(listOf("photo", "photos"))
        if (e.isFavorite) addAll(listOf("favorite", "favourite", "favorites"))
        if (e.asset?.bucketName.equals("Screenshots", ignoreCase = true)) addAll(listOf("screenshot", "screenshots"))
    }

    /** A place suggestion: its name, how many photos, and the newest one for its cover. */
    data class Place(val name: String, val count: Int, val coverId: String)

    data class Suggestions(val places: List<Place>, val months: List<String>)

    /** The places with the most photos (by city, the first part of the name), and the newest months. */
    fun suggestions(
        entries: List<GalleryEntry>, places: Map<String, String>, phone: (String) -> Pair<Double, Double>?,
        limit: Int = 10, zone: ZoneId = ZoneId.systemDefault(), locale: Locale = Locale.getDefault(),
    ): Suggestions {
        val month = DateTimeFormatter.ofPattern("LLLL yyyy", locale)
        val counts = HashMap<String, Int>()
        val covers = HashMap<String, String>()
        val months = LinkedHashSet<String>()
        for (e in entries) {
            val name = cell(e, phone)?.let { places[it] }?.substringBefore(',')?.trim()?.takeIf { it.isNotEmpty() }
            if (name != null) {
                counts.merge(name, 1, Int::plus)
                // Entries are newest first: the first one seen is the cover.
                covers.putIfAbsent(name, e.id)
            }
            if (e.date != null && months.size < limit) months += month.format(Instant.ofEpochMilli(e.date).atZone(zone))
        }
        val top = counts.entries.sortedWith(compareByDescending<Map.Entry<String, Int>> { it.value }.thenBy { it.key })
            .take(limit).map { Place(it.key, it.value, covers.getValue(it.key)) }
        return Suggestions(top, months.toList())
    }
}
