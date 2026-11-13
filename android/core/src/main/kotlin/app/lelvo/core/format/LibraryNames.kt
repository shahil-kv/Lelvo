package app.lelvo.core.format

/**
 * The suggested name for a new library: "Lelvo Library", or "Lelvo Library 2" (3, …) when that name is taken, so two
 * libraries never look the same in the list or in Telegram (iOS `LibraryNames`).
 */
object LibraryNames {
    const val DEFAULT = "Lelvo Library"

    // The channel sits in the user's Telegram chat list next to their other chats. The warning around its name is
    // there so nobody clears it out by mistake; inside the app only the plain name shows.
    private const val PREFIX = "🚨 "
    private const val SUFFIX = " · Do not delete 🚨"

    /** Telegram allows 128 characters in a channel title; this leaves room for the warning. */
    const val MAX_NAME_LENGTH = 100

    fun unused(base: String, taken: List<String>): String {
        val used = taken.map { it.trim().lowercase() }.toSet()
        if (base.lowercase() !in used) return base
        var n = 2
        while ("$base $n".lowercase() in used) n++
        return "$base $n"
    }

    /** The channel title in Telegram for a library name: "🚨 Lelvo Library · Do not delete 🚨". */
    fun channelTitle(name: String): String = PREFIX + plain(name).take(MAX_NAME_LENGTH) + SUFFIX

    /**
     * The library name for a channel title, without the warning. Titles without it (older libraries, or a name the
     * user changed in Telegram) come back as they are.
     */
    fun plain(title: String): String {
        var name = title.trim()
        if (name.startsWith(PREFIX) && name.endsWith(SUFFIX) && name.length >= PREFIX.length + SUFFIX.length) {
            name = name.removePrefix(PREFIX).removeSuffix(SUFFIX)
        }
        return name.trim()
    }
}
