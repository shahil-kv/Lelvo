package app.lelvo.core.search

import app.lelvo.core.memories.Memories
import java.text.Normalizer
import java.time.Instant
import java.time.ZoneId
import java.time.format.TextStyle
import java.util.Locale

/**
 * On-device search (iOS `SearchMatcher`): every word of the query must start a word the photo is known by: its place,
 * its kind, its album, folder or file name, or its date ("june", "2023", "june 2023").
 */
object SearchMatcher {
    private val marks = Regex("\\p{M}+")
    private val separators = Regex("[^\\p{L}\\p{N}]+")

    /** Lowercased words without accents, so "Café" finds "cafe". */
    fun words(text: String): List<String> =
        Normalizer.normalize(text, Normalizer.Form.NFD).replace(marks, "").lowercase(Locale.ROOT)
            .split(separators).filter { it.isNotEmpty() }

    private val english = listOf("january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december")

    /**
     * The words a date is found by: the year, and the month in English and in the phone's language (the month
     * suggestions are written in the user's language, so "juin 2023" must find June).
     */
    fun dateWords(date: Long?, zone: ZoneId = ZoneId.systemDefault(), locale: Locale = Locale.getDefault()): List<String> {
        date ?: return emptyList()
        val d = Instant.ofEpochMilli(date).atZone(zone)
        val out = mutableListOf(d.year.toString(), english[d.monthValue - 1])
        val local = d.month.getDisplayName(TextStyle.FULL, locale) + " " + d.month.getDisplayName(TextStyle.FULL_STANDALONE, locale)
        for (name in words(local)) if (name !in out) out += name
        return out
    }

    /**
     * What people type for things named differently ("sea" for a photo of the ocean). Whole words only, so typing
     * "be" doesn't bring up the ocean. Same list as iOS, so both apps find the same photos.
     */
    private val alternatives = mapOf(
        "beach" to listOf("shore", "ocean", "sand", "coast"),
        "beaches" to listOf("beach", "shore", "ocean", "sand", "coast"),
        "sea" to listOf("ocean", "shore", "beach"),
        "ocean" to listOf("sea", "shore"),
        "mountains" to listOf("mountain", "hill"),
        "mountain" to listOf("hill"),
        "bike" to listOf("motorcycle", "bicycle"),
        "car" to listOf("vehicle"),
        "kid" to listOf("child"),
        "kids" to listOf("child"),
        "pet" to listOf("dog", "cat"),
        "pets" to listOf("dog", "cat"),
    )

    /** A query word and the other words that count as it. */
    fun variants(term: String): List<String> = listOf(term) + alternatives[term].orEmpty()

    /** Whether every query word, or a word that counts as it, starts one of [known] (already passed through [words]). */
    fun matches(query: List<String>, known: List<String>): Boolean =
        query.isNotEmpty() && query.all { term -> variants(term).any { v -> known.any { it.startsWith(v) } } }

    /** The ~1 km grid cell a location falls in; place names are looked up once per cell. */
    fun placeCell(latitude: Double, longitude: Double): String = Memories.placeCell(latitude, longitude)

    private val iso6709 = Regex("""^([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)""")

    /** A video's location tag, ISO 6709 as Android writes it: "+37.4219-122.0840/" (an altitude may follow). */
    fun parseIso6709(text: String): Pair<Double, Double>? {
        val m = iso6709.find(text.trim()) ?: return null
        val lat = m.groupValues[1].toDoubleOrNull() ?: return null
        val lon = m.groupValues[2].toDoubleOrNull() ?: return null
        return lat to lon
    }
}

/**
 * An inverted index (iOS `SearchIndex`): every known word once, sorted, with the entries it belongs to. A query word
 * is found by binary search for the words it starts, so typing stays instant in a big library.
 */
class SearchIndex(entries: List<Pair<String, List<String>>>) {
    private val words: Array<String>
    private val postings: Array<IntArray>
    /** Entry ids in timeline order; results come back in this order. */
    private val ids: Array<String> = Array(entries.size) { entries[it].first }

    init {
        val map = HashMap<String, MutableList<Int>>()
        entries.forEachIndexed { i, (_, ws) -> for (w in ws.toHashSet()) map.getOrPut(w) { mutableListOf() } += i }
        words = map.keys.sorted().toTypedArray()
        postings = Array(words.size) { map.getValue(words[it]).toIntArray() }
    }

    val count: Int get() = ids.size

    /** Ids of the entries where every query word starts one of their words, in timeline order. */
    fun search(query: String): List<String> {
        val terms = SearchMatcher.words(query)
        if (terms.isEmpty()) return emptyList()
        val found = terms.map { t -> SearchMatcher.variants(t).fold(HashSet<Int>()) { acc, v -> acc.apply { addAll(matches(v)) } } }
        // The rarest word first keeps the intersections small.
        var result: MutableSet<Int>? = null
        for (term in found.sortedBy { it.size }) {
            result = result?.apply { retainAll(term) } ?: HashSet(term)
            if (result.isEmpty()) return emptyList()
        }
        return result.orEmpty().sorted().map { ids[it] }
    }

    /** Every entry with a word starting with [prefix]. */
    private fun matches(prefix: String): Set<Int> {
        var lo = 0
        var hi = words.size
        while (lo < hi) {
            val mid = (lo + hi) ushr 1
            if (words[mid] < prefix) lo = mid + 1 else hi = mid
        }
        val out = HashSet<Int>()
        var i = lo
        while (i < words.size && words[i].startsWith(prefix)) { postings[i].forEach { out += it }; i++ }
        return out
    }

    companion object { val empty = SearchIndex(emptyList()) }
}
