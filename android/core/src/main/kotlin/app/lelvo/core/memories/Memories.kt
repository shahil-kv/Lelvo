package app.lelvo.core.memories

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.temporal.ChronoUnit
import java.time.temporal.WeekFields
import java.util.Locale
import kotlin.math.abs
import kotlin.math.asin
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.min
import kotlin.math.sign
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * On-device Memories, a port of iOS `Memories` with the same rules and numbers: "N years ago" on this day, recent
 * highlights, trips, and themes. Trips follow Ente's open-source trip calculator: a run of photos far from every
 * place you often are ("bases"), over two days or more. Dates are epoch milliseconds; days are counted in [zone].
 */
object Memories {
    data class Photo(
        val id: String,
        val date: Long,
        val latitude: Double? = null,
        val longitude: Double? = null,
        /** Image labels (iOS: Vision's identifiers). None on Android until it has an on-device labeller. */
        val things: List<String> = emptyList(),
        /** Aesthetics score (-1…1), when known. */
        val score: Double? = null,
        /** A screenshot, receipt or document: never part of a memory. */
        val isUtility: Boolean = false,
    ) {
        internal val location: Pair<Double, Double>?
            get() {
                val lat = latitude ?: return null
                val lon = longitude ?: return null
                return if (lat == 0.0 && lon == 0.0) null else lat to lon
            }
    }

    sealed interface Kind {
        data class OnThisDay(val yearsAgo: Int) : Kind
        data object Trip : Kind
        data object Recent : Kind
        data class Theme(val theme: Memories.Theme) : Kind
    }

    enum class Theme(val title: String, val labels: Set<String>) {
        Dogs("Dogs", setOf("dog", "canine", "bulldog", "sheepdog")),
        Cats("Cats", setOf("cat", "feline", "adult_cat")),
        Beach("At the Beach", setOf("beach", "shore", "ocean")),
        Snow("Snow Days", setOf("snow", "snowman", "skiing", "snowboarding")),
        Food("Good Food", setOf("food", "dessert", "seafood")),
        Celebrations("Celebrations", setOf("birthday_cake", "celebration", "fireworks", "wedding", "christmas_tree", "christmas_decoration")),
        Mountains("Mountains", setOf("mountain", "hiking")),
        Sunsets("Sunsets", setOf("sunset_sunrise")),
        Flowers("Flowers", setOf("flower", "flower_arrangement")),
    }

    /** The memory types a user can turn off, like Google Photos' settings. */
    enum class KindFilter(val key: String) { OnThisDay("onThisDay"), Recent("recent"), Trips("trips"), Themes("themes") }

    data class Memory(
        val kind: Kind,
        /** The photos the memory plays, oldest first: a few, spread over it ([select]). */
        val ids: List<String>,
        /** Every photo of the memory, oldest first (Show all). */
        val allIds: List<String>,
        val start: Long,
        val end: Long,
        /** The best-looking photo, else the middle one. */
        val cover: String,
        /** The [placeCell] most of its photos were taken in, for naming a trip. */
        val placeCell: String?,
    ) {
        val id: String get() = "$kind-${allIds.firstOrNull().orEmpty()}"
    }

    // The trip numbers are iOS's (which explains each against Ente's).
    const val BASE_RADIUS_KM = 10.0
    const val BASE_MINIMUM_DAYS = 10
    const val BASE_MINIMUM_WEEKS = 6
    const val BASE_MINIMUM_MONTHS = 2
    const val BASE_MINIMUM_SPAN_DAYS = 91L
    const val BASE_DENSE_DAYS = 12
    const val BASE_DENSE_WINDOW_DAYS = 120L
    const val SAME_AREA_KM = 25.0
    const val MOVING_GAP_DAYS = 2.0
    const val MOVING_HOP_KM = 800.0
    const val TRIP_MINIMUM_PHOTOS = 20
    val TRIP_DAYS = 2..90
    /** Longer than this, a trip is titled as a stay ("Time in Lisbon"). */
    const val LONG_STAY_DAYS = 14
    const val STORY_LENGTH = 20
    const val SELECTION_GAP_MS = 10 * 60 * 1000L
    const val MINIMUM_PHOTOS = 12
    const val MINIMUM_DAYS = 3
    const val RECENT_DAYS = 30
    private const val DAY_MS = 86_400_000L

    /** The ~1 km grid cell a location falls in (iOS `SearchMatcher.placeCell`, same text). */
    fun placeCell(latitude: Double, longitude: Double): String {
        // Swift's `rounded()` rounds halves away from zero.
        fun r(x: Double) = sign(x) * floor(abs(x * 100) + 0.5) / 100
        return String.format(Locale.ROOT, "%.2f,%.2f", r(latitude), r(longitude))
    }

    /** Everything to show, in the Memories screen's order: on this day, recent highlights, trips, themes. */
    fun all(photos: List<Photo>, today: Long, zone: ZoneId, kinds: Set<KindFilter> = KindFilter.entries.toSet()): List<Memory> {
        val usable = photos.filter { !it.isUtility }
        val out = ArrayList<Memory>()
        if (KindFilter.OnThisDay in kinds) out += onThisDay(usable, today, zone)
        if (KindFilter.Recent in kinds) recent(usable, today, zone)?.let(out::add)
        if (KindFilter.Trips in kinds) out += trips(usable, zone)
        if (KindFilter.Themes in kinds) out += themes(usable, zone)
        return out
    }

    private fun day(ms: Long, zone: ZoneId): LocalDate = Instant.ofEpochMilli(ms).atZone(zone).toLocalDate()

    /** The best of the last [RECENT_DAYS] days. */
    fun recent(photos: List<Photo>, today: Long, zone: ZoneId): Memory? {
        val since = today - RECENT_DAYS * DAY_MS
        val list = photos.filter { it.date in since..today }
        if (list.size < MINIMUM_PHOTOS || list.mapTo(HashSet()) { day(it.date, zone) }.size < MINIMUM_DAYS) return null
        return memory(Kind.Recent, list)
    }

    /** One memory per theme with enough photos over enough days, the biggest first. */
    fun themes(photos: List<Photo>, zone: ZoneId): List<Memory> =
        Theme.entries.mapNotNull { theme ->
            val list = photos.filter { p -> p.things.any { it in theme.labels } }
            if (list.size < MINIMUM_PHOTOS || list.mapTo(HashSet()) { day(it.date, zone) }.size < MINIMUM_DAYS) null
            else memory(Kind.Theme(theme), list)
        }.sortedByDescending { it.allIds.size }

    /** Photos taken on today's month and day in earlier years, one memory per year, most recent year first. */
    fun onThisDay(photos: List<Photo>, today: Long, zone: ZoneId, minimumPhotos: Int = 3): List<Memory> {
        val now = day(today, zone)
        val byYear = HashMap<Int, MutableList<Photo>>()
        for (p in photos) {
            val d = day(p.date, zone)
            if (d.year < now.year && d.monthValue == now.monthValue && d.dayOfMonth == now.dayOfMonth) byYear.getOrPut(d.year) { ArrayList() } += p
        }
        return byYear.filter { it.value.size >= minimumPhotos }.entries.sortedByDescending { it.key }
            .map { (year, list) -> memory(Kind.OnThisDay(now.year - year), list) }
    }

    /**
     * The ~1 km areas of the places you keep coming back to. Each place is judged with everything within
     * [BASE_RADIUS_KM] of its busiest area (your town, not one street).
     */
    fun bases(photos: List<Photo>, zone: ZoneId): List<Pair<Double, Double>> {
        class Area { val days = HashSet<LocalDate>(); var lat = 0.0; var lon = 0.0; var n = 0.0 }
        val areas = HashMap<String, Area>()
        for (p in photos) {
            val (lat, lon) = p.location ?: continue
            val a = areas.getOrPut(placeCell(lat, lon)) { Area() }
            a.days += day(p.date, zone)
            a.lat += lat; a.lon += lon; a.n += 1
        }
        val unassigned = areas.entries.sortedWith(compareByDescending<Map.Entry<String, Area>> { it.value.days.size }.thenBy { it.key })
            .map { (it.value.lat / it.value.n to it.value.lon / it.value.n) to it.value }
            .toMutableList()
        val bases = ArrayList<Pair<Double, Double>>()
        while (unassigned.isNotEmpty()) {
            val seed = unassigned.first()
            val region = unassigned.filter { kilometres(seed.first, it.first) < BASE_RADIUS_KM }
            unassigned.removeAll { kilometres(seed.first, it.first) < BASE_RADIUS_KM }
            val days = region.flatMapTo(HashSet()) { it.second.days }
            // Every area of a home place counts, so "near home" means near any of its streets, not its middle.
            if (isHome(days.sorted())) bases += region.map { it.first }
        }
        return bases
    }

    /** Ente's base test on the days an area has photos. */
    internal fun isHome(days: List<LocalDate>): Boolean {
        if (days.size < BASE_MINIMUM_DAYS) return false
        if (ChronoUnit.DAYS.between(days.first(), days.last()) < BASE_MINIMUM_SPAN_DAYS) return false
        val wf = WeekFields.ISO
        val weeks = days.mapTo(HashSet()) { it.get(wf.weekBasedYear()) to it.get(wf.weekOfWeekBasedYear()) }
        val months = days.mapTo(HashSet()) { it.year to it.monthValue }
        if (weeks.size < BASE_MINIMUM_WEEKS || months.size < BASE_MINIMUM_MONTHS) return false
        var start = 0
        for (end in days.indices) {
            while (ChronoUnit.DAYS.between(days[start], days[end]) > BASE_DENSE_WINDOW_DAYS) start++
            if (end - start + 1 >= BASE_DENSE_DAYS) return true
        }
        return false
    }

    /** Trips, newest first. No home places (too few photos with a location) means no trips. */
    fun trips(photos: List<Photo>, zone: ZoneId): List<Memory> {
        val bases = bases(photos, zone)
        if (bases.isEmpty()) return emptyList()
        val trips = ArrayList<Memory>()
        var run = ArrayList<Photo>()
        var aLat = 0.0; var aLon = 0.0; var aN = 0.0
        // Photos without a location taken during a trip (sent by friends, location off) belong to it too.
        val unplaced = photos.filter { it.location == null }.sortedBy { it.date }
        fun close() {
            val r = run
            run = ArrayList(); val centre = aLat / aN to aLon / aN
            aLat = 0.0; aLon = 0.0; aN = 0.0
            if (r.size < TRIP_MINIMUM_PHOTOS) return
            val first = r.first().date
            val last = r.last().date
            val days = ChronoUnit.DAYS.between(day(first, zone), day(last, zone)).toInt() + 1
            if (days !in TRIP_DAYS) return
            if (!bases.all { kilometres(it, centre) >= BASE_RADIUS_KM }) return
            trips += memory(Kind.Trip, r + unplaced.filter { it.date in first..last })
        }
        for (p in photos.sortedBy { it.date }) {
            val location = p.location ?: continue
            if (bases.any { kilometres(it, location) < BASE_RADIUS_KM }) { close(); continue }
            val last = run.lastOrNull()
            val lastLocation = last?.location
            if (last != null && lastLocation != null) {
                val gap = (p.date - last.date) / DAY_MS.toDouble()
                val centre = aLat / aN to aLon / aN
                val moving = gap <= MOVING_GAP_DAYS && kilometres(lastLocation, location) <= MOVING_HOP_KM
                val stillThere = kilometres(centre, location) <= SAME_AREA_KM
                val tooLong = p.date - run[0].date > TRIP_DAYS.last * DAY_MS
                if (tooLong || !(moving || stillThere)) close()
            }
            run += p
            aLat += location.first; aLon += location.second; aN += 1
        }
        close()
        return trips.reversed()
    }

    /**
     * Up to [limit] photos spread over the memory: cut into equal runs, the best-looking of each (the first when no
     * scores are known), at least [gap] after the one before so a burst shows once.
     */
    fun select(photos: List<Photo>, limit: Int = STORY_LENGTH, gap: Long = SELECTION_GAP_MS): List<Photo> {
        val ordered = photos.sortedBy { it.date }
        if (ordered.size <= limit) return ordered
        val picked = ArrayList<Photo>()
        val step = ordered.size.toDouble() / limit
        for (i in 0 until limit) {
            val bucket = ordered.subList((i * step).toInt(), min(ordered.size, ((i + 1) * step).toInt()))
            val candidates = bucket.filter { p -> picked.lastOrNull()?.let { p.date - it.date >= gap } ?: true }
            val best = candidates.maxWithOrNull(compareBy<Photo> { it.score ?: -2.0 }.thenByDescending { it.date }) ?: continue
            picked += best
        }
        return picked
    }

    private fun memory(kind: Kind, list: List<Photo>): Memory {
        val ordered = list.sortedBy { it.date }
        val cells = HashMap<String, Int>()
        for (p in ordered) p.location?.let { (lat, lon) -> cells.merge(placeCell(lat, lon), 1, Int::plus) }
        val story = select(ordered)
        val cover = story.filter { it.score != null }.maxWithOrNull(compareBy { it.score!! }) ?: story[story.size / 2]
        val place = cells.entries.maxWithOrNull(compareBy<Map.Entry<String, Int>> { it.value }.thenByDescending { it.key })?.key
        return Memory(kind, story.map { it.id }, ordered.map { it.id }, ordered.first().date, ordered.last().date, cover.id, place)
    }

    internal fun kilometres(a: Pair<Double, Double>, b: Pair<Double, Double>): Double {
        val r = 6371.0
        val rad = Math.PI / 180
        val dLat = (b.first - a.first) * rad
        val dLon = (b.second - a.second) * rad
        val h = sin(dLat / 2) * sin(dLat / 2) + cos(a.first * rad) * cos(b.first * rad) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1.0, sqrt(h)))
    }
}
