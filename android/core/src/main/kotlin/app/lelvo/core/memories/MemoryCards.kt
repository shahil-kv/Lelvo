package app.lelvo.core.memories

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.Locale

/** A memory with its title and subtitle, worded like iOS `MemoriesModel.cards` (and Apple's and Google's). */
data class MemoryCard(val memory: Memories.Memory, val title: String, val subtitle: String) {
    val id: String get() = memory.id
}

object MemoryCards {
    /** [placeName] names a `placeCell` when the phone knows it (search reads place names); null leaves it out. */
    fun of(memories: List<Memories.Memory>, zone: ZoneId, locale: Locale = Locale.getDefault(), placeName: (String) -> String? = { null }): List<MemoryCard> {
        val month = DateTimeFormatter.ofPattern("MMMM yyyy", locale)
        val dayMonth = DateTimeFormatter.ofPattern("d MMMM yyyy", locale)
        fun fmt(f: DateTimeFormatter, ms: Long) = f.format(Instant.ofEpochMilli(ms).atZone(zone))
        fun place(m: Memories.Memory) = m.placeCell?.let(placeName)
        fun span(m: Memories.Memory): String {
            val a = fmt(month, m.start)
            val b = fmt(month, m.end)
            return if (a == b) a else "$a – $b"
        }
        return memories.map { m ->
            when (val k = m.kind) {
                is Memories.Kind.OnThisDay -> MemoryCard(
                    m, if (k.yearsAgo == 1) "One Year Ago" else "${k.yearsAgo} Years Ago",
                    listOfNotNull(fmt(dayMonth, m.start), place(m)).joinToString(" · "),
                )
                Memories.Kind.Recent -> MemoryCard(m, "Recent Highlights", span(m))
                Memories.Kind.Trip -> {
                    val days = ChronoUnit.DAYS.between(Instant.ofEpochMilli(m.start).atZone(zone).toLocalDate(), Instant.ofEpochMilli(m.end).atZone(zone).toLocalDate()).toInt() + 1
                    // A long stay reads like Photos': "Time in Dubai", from the first month to the last.
                    val long = days > Memories.LONG_STAY_DAYS
                    val title = place(m)?.let { if (long) "Time in $it" else "Trip to $it" } ?: if (long) "Away, ${span(m)}" else "Trip in ${fmt(month, m.start)}"
                    MemoryCard(m, title, if (long) "${span(m)} · $days days" else "${fmt(month, m.start)} · $days days")
                }
                is Memories.Kind.Theme -> MemoryCard(m, k.theme.title, "${m.allIds.size} photos · ${span(m)}")
            }
        }
    }
}
