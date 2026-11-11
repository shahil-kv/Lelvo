package app.lelvo.core.index

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/**
 * What the Collections tab shows, in one pass over the timeline (iOS `AlbumsView.recompute`): Recent Days, albums,
 * the phone's folders and media types, each with its count and cover (the newest entry). Albums are Lelvo's own,
 * shared through the captions and the albums notes; folders are Android's (Google Photos' "Photos on device").
 */
object Collections {
    data class Row(val filter: GalleryFilter, val count: Int, val cover: GalleryEntry?)

    data class Content(
        val days: List<Row> = emptyList(),
        val albums: List<Row> = emptyList(),
        val folders: List<Row> = emptyList(),
        val media: List<Row> = emptyList(),
    )

    /** The phone's camera and screenshots come first, like Google Photos; then the folder with the newest photo. */
    private val firstFolders = listOf("Camera", "Screenshots")

    /**
     * [entries] newest first, as the timeline has them. [dayTitle] names a day other than today and yesterday.
     * Recent Days are the last [dayCount] days with photos.
     */
    fun build(entries: List<GalleryEntry>, zone: ZoneId, today: LocalDate, dayTitle: (LocalDate) -> String, dayCount: Int = 10): Content {
        val days = ArrayList<Pair<LocalDate, MutableList<GalleryEntry>>>()
        var daysDone = false
        val albums = HashMap<String, MutableList<GalleryEntry>>()
        val folders = LinkedHashMap<String, Pair<String, MutableList<GalleryEntry>>>()
        val media = GalleryFilter.entries.associateWith { ArrayList<GalleryEntry>() }
        for (e in entries) {
            if (!daysDone) e.date?.let { ms ->
                val day = Instant.ofEpochMilli(ms).atZone(zone).toLocalDate()
                val last = days.lastOrNull()
                when {
                    last?.first == day -> last.second += e
                    days.size == dayCount -> daysDone = true
                    else -> days += day to mutableListOf(e)
                }
            }
            e.item?.albums?.forEach { albums.getOrPut(it) { ArrayList() } += e }
            e.asset?.let { a -> a.bucketId?.let { id -> folders.getOrPut(id) { (a.bucketName ?: "Internal storage") to ArrayList() }.second += e } }
            for ((f, list) in media) if (f.matches(e)) list += e
        }
        fun row(f: GalleryFilter, list: List<GalleryEntry>) = Row(f, list.size, list.firstOrNull())
        val dayRows = days.map { (day, list) ->
            val title = when (day) {
                today -> "Today"
                today.minusDays(1) -> "Yesterday"
                else -> dayTitle(day)
            }
            row(GalleryFilter.Matching(title, list.mapTo(HashSet()) { it.id }), list)
        }
        val favorites = media.getValue(GalleryFilter.Favorites)
        val albumRows = buildList {
            if (favorites.isNotEmpty()) add(row(GalleryFilter.Favorites, favorites))
            albums.entries.sortedWith(compareBy<Map.Entry<String, List<GalleryEntry>>, String>(String.CASE_INSENSITIVE_ORDER) { it.key }.thenBy { it.key }).forEach { add(row(GalleryFilter.Album(it.key), it.value)) }
        }
        val folderRows = folders.map { (id, v) -> row(GalleryFilter.Folder(v.first, id), v.second) }
            .sortedWith(
                compareBy<Row> { firstFolders.indexOf(it.filter.title).let { i -> if (i < 0) firstFolders.size else i } }
                    .thenByDescending { it.cover?.date ?: Long.MIN_VALUE },
            )
        val mediaRows = listOf(GalleryFilter.Videos, GalleryFilter.LivePhotos, GalleryFilter.CloudOnly, GalleryFilter.NotBackedUp)
            .mapNotNull { f -> media.getValue(f).takeIf { it.isNotEmpty() }?.let { row(f, it) } }
        return Content(dayRows, albumRows, folderRows, mediaRows)
    }
}
