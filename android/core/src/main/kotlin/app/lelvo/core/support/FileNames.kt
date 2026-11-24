package app.lelvo.core.support

/** File names for files written on this phone (iOS `FileNames`). */
object FileNames {
    /** Most file systems allow 255 bytes per name; kept well below. */
    const val MAX_BYTES = 160

    private val unsafe = Regex("[/\\\\:?%*|\"<>\n\r]")

    /**
     * [name] with path characters replaced, cut to [maxBytes] UTF-8 bytes with its extension kept. The full name stays in
     * the caption: only the file on the phone is shorter (I13, a 228-character name).
     */
    fun safe(name: String, maxBytes: Int = MAX_BYTES): String {
        val cleaned = name.replace(unsafe, "_")
        if (cleaned.isEmpty()) return "file"
        if (cleaned.toByteArray().size <= maxBytes) return cleaned
        val dot = cleaned.lastIndexOf('.')
        val ext = if (dot > 0 && cleaned.length - dot - 1 in 1..16) cleaned.substring(dot + 1) else ""
        var base = if (ext.isEmpty()) cleaned else cleaned.substring(0, dot)
        val room = maxBytes - if (ext.isEmpty()) 0 else ext.toByteArray().size + 1
        // Drop whole code points, so an emoji is never split.
        while (base.toByteArray().size > room) base = base.substring(0, base.offsetByCodePoints(base.length, -1))
        if (base.isEmpty()) base = "file"
        return if (ext.isEmpty()) base else "$base.$ext"
    }
}
