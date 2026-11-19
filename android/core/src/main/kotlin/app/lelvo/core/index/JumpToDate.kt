package app.lelvo.core.index

import java.util.Calendar

/**
 * Maps a calendar date to the scrubber's 0…1 fraction. Newest-first: 0 is the top (newest), 1 is the bottom
 * (oldest). Mirrors iOS `JumpToDate`.
 */
object JumpToDate {
    /** Where to scroll for [targetMs] in a newest-first epoch-ms list. Empty or one item → 0. */
    fun fraction(targetMs: Long, datesNewestFirst: LongArray): Double {
        if (datesNewestFirst.size <= 1) return 0.0
        val i = datesNewestFirst.indexOfFirst { it <= targetMs }
        if (i < 0) return 1.0
        return i.toDouble() / (datesNewestFirst.size - 1)
    }

    /** Inclusive year range from the library (and today's year). Empty → current year only. */
    fun yearRange(datesMs: LongArray, nowMs: Long = System.currentTimeMillis()): IntRange {
        val cal = Calendar.getInstance()
        cal.timeInMillis = nowMs
        val thisYear = cal.get(Calendar.YEAR)
        if (datesMs.isEmpty()) return thisYear..thisYear
        var lo = thisYear
        var hi = thisYear
        for (ms in datesMs) {
            cal.timeInMillis = ms
            val y = cal.get(Calendar.YEAR)
            if (y < lo) lo = y
            if (y > hi) hi = y
        }
        return lo..hi
    }
}
