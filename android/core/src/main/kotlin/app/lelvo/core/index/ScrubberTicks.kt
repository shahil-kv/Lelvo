package app.lelvo.core.index

/** Where a year starts along the date scrubber, as the platform measured it (a fraction from the top, 0 to 1). */
data class ScrubberMark(val year: Int, val fraction: Double)

/**
 * Picks the year labels drawn along the scrubber track (iOS `ScrubberTicks`). The positions come from the real library,
 * so a library that starts in 2015 ends its track at 2015 and one with a gap years wide keeps the gap: nothing is
 * spread evenly over time.
 */
object ScrubberTicks {
    /** Short libraries need no marks: the scrubber's bubble is enough. */
    const val MINIMUM_VIEWPORTS = 8.0

    /**
     * [marks] in track order (top first), one per section. Consecutive marks of the same year become one label at the
     * first of them; labels closer than one slot (`1 / maxLabels` of the track) to the last kept one are dropped.
     */
    fun make(marks: List<ScrubberMark>, maxLabels: Int): List<ScrubberMark> {
        if (maxLabels <= 0) return emptyList()
        val yearStarts = ArrayList<ScrubberMark>()
        for (mark in marks) {
            if (!mark.fraction.isFinite()) continue
            if (yearStarts.lastOrNull()?.year == mark.year) continue
            yearStarts += ScrubberMark(mark.year, mark.fraction.coerceIn(0.0, 1.0))
        }
        val slot = 1.0 / maxLabels
        val kept = ArrayList<ScrubberMark>()
        for (mark in yearStarts) {
            val last = kept.lastOrNull()
            if (last != null && mark.fraction - last.fraction < slot) continue
            kept += mark
        }
        return kept
    }

    /** Whether the library is long enough to draw marks at all. */
    fun isLongEnough(contentHeight: Double, viewportHeight: Double): Boolean =
        viewportHeight > 0 && contentHeight / viewportHeight > MINIMUM_VIEWPORTS
}
