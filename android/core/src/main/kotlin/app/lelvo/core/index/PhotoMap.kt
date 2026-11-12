package app.lelvo.core.index

/** One photo or video on the map (iOS `PhotoPin`). */
data class MapPin(val id: String, val lat: Double, val lon: Double, val date: Long)

/** Pins near each other on screen, shown as the newest one's thumbnail and a count (iOS `MKClusterAnnotation`). */
data class MapCluster(val cover: MapPin, val ids: List<String>) {
    val count: Int get() = ids.size
}

object PhotoMap {
    /**
     * The pins for [entries]: a phone photo's own location ([phoneLocation], read from the file), otherwise the
     * backup's. 0,0 is a missing location written as zeros, not a photo in the Gulf of Guinea (as on iOS).
     */
    fun pins(entries: List<GalleryEntry>, phoneLocation: (String) -> Pair<Double, Double>?): List<MapPin> =
        entries.mapNotNull { e ->
            val place = e.asset?.let { phoneLocation(it.localId) }
                ?: e.item?.let { i -> i.latitude?.let { lat -> i.longitude?.let { lon -> lat to lon } } }
                ?: return@mapNotNull null
            val (lat, lon) = place
            if (!valid(lat, lon)) return@mapNotNull null
            MapPin(e.id, lat, lon, e.date ?: Long.MIN_VALUE)
        }

    fun valid(lat: Double, lon: Double): Boolean =
        !lat.isNaN() && !lon.isNaN() && lat in -90.0..90.0 && lon in -180.0..180.0 && !(lat == 0.0 && lon == 0.0)

    /**
     * Groups pins whose screen positions fall in the same [cell] (pixels square), the way the iPhone's map groups
     * overlapping photos. [screen] gives a pin's position on screen, or null when it is off screen; those are left
     * out. Each group's cover is its newest photo, so the thumbnail shown is the latest taken there.
     */
    fun cluster(pins: List<MapPin>, cell: Float, screen: (MapPin) -> Pair<Float, Float>?): List<MapCluster> {
        require(cell > 0f)
        val groups = LinkedHashMap<Long, MutableList<MapPin>>()
        for (p in pins) {
            val (x, y) = screen(p) ?: continue
            val key = (Math.floorDiv(x.toInt(), cell.toInt()).toLong() shl 32) or (Math.floorDiv(y.toInt(), cell.toInt()).toLong() and 0xffffffffL)
            groups.getOrPut(key) { ArrayList() } += p
        }
        return groups.values.map { g -> MapCluster(g.maxBy { it.date }, g.sortedByDescending { it.date }.map { it.id }) }
    }

    /** South-west and north-east corners around every pin, for the first view of the map. Null with no pins. */
    fun bounds(pins: List<MapPin>): Pair<Pair<Double, Double>, Pair<Double, Double>>? {
        if (pins.isEmpty()) return null
        return (pins.minOf { it.lat } to pins.minOf { it.lon }) to (pins.maxOf { it.lat } to pins.maxOf { it.lon })
    }
}
