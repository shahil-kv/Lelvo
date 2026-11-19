package app.lelvo.core.index

/** EXIF `OffsetTimeOriginal` in whole minutes, the caption's `tz` (iOS `ExifDate.offsetMinutes`, I14). */
object ExifOffset {
    private val pattern = Regex("""^([+-])(\d{2}):?(\d{2})(?::?\d{2})?$""")

    /** `±HH:MM`, `±HH:MM:SS` or `±HHMM`; null for anything else. */
    fun minutes(text: String?): Int? {
        val m = pattern.matchEntire(text?.trim() ?: return null) ?: return null
        val (sign, h, min) = m.destructured
        val hours = h.toInt()
        val minutes = min.toInt()
        if (hours > 14 || minutes > 59) return null
        return (hours * 60 + minutes) * if (sign == "-") -1 else 1
    }
}
