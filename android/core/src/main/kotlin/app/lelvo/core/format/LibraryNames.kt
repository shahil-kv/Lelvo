package app.lelvo.core.format

/**
 * The suggested name for a new library: "Lelvo Library", or "Lelvo Library 2" (3, …) when that name is taken, so two
 * libraries never look the same in the list or in Telegram (iOS `LibraryNames`).
 */
object LibraryNames {
    const val DEFAULT = "Lelvo Library"

    fun unused(base: String, taken: List<String>): String {
        val used = taken.map { it.trim().lowercase() }.toSet()
        if (base.lowercase() !in used) return base
        var n = 2
        while ("$base $n".lowercase() in used) n++
        return "$base $n"
    }
}
