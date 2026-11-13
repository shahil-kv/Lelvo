package app.lelvo.core.media

/**
 * Finds the video inside an Android Motion Photo: one JPEG or HEIC file with an MP4 appended. Phones mark it three
 * ways, tried in order:
 * - Camera XMP v1 (Pixel since 2021, most phones now): `Camera:MotionPhoto="1"` and a container directory whose
 *   `MotionPhoto` item gives the video's length, counted from the end of the file;
 * - the older Google one: `GCamera:MicroVideo="1"` with `GCamera:MicroVideoOffset`, also from the end;
 * - Samsung's trailer (ends with `SEFT`), whose `MotionPhoto_Data` entry holds the video.
 * Every answer is checked: an MP4 starts with a `ftyp` box, so a wrong offset is never played.
 */
object MotionPhoto {
    /** Reads [length] bytes at [offset] of the file; fewer only at its end. */
    fun interface Reader {
        fun read(offset: Long, length: Int): ByteArray
    }

    /** XMP sits in the first part of the file (JPEG APP1, or HEIC's `mime` item, which comes early too). */
    const val HEAD_BYTES = 256 * 1024

    /** Where the video starts and how long it is, or null when the file isn't a Motion Photo. */
    data class Video(val start: Long, val length: Long)

    fun find(fileLength: Long, read: Reader): Video? {
        if (fileLength < 16) return null
        val head = read.read(0, minOf(HEAD_BYTES.toLong(), fileLength).toInt())
        fromXmp(String(head, Charsets.ISO_8859_1), fileLength)?.let { start -> verified(start, fileLength, read)?.let { return it } }
        return fromSamsungTrailer(fileLength, read)
    }

    /** The video's start from the XMP text, before checking: from the end of the file in both Google schemes. */
    internal fun fromXmp(xmp: String, fileLength: Long): Long? {
        val isMotion = attr(xmp, "MotionPhoto") == "1" || attr(xmp, "MicroVideo") == "1"
        if (!isMotion) return null
        // Camera XMP v1: the directory's item with Semantic="MotionPhoto" and its Length.
        Regex("""<[\w]+:Item\b[^>]*>""").findAll(xmp).forEach { m ->
            val tag = m.value
            if (attr(tag, "Semantic") == "MotionPhoto") {
                val length = attr(tag, "Length")?.toLongOrNull() ?: return@forEach
                if (length in 1 until fileLength) return fileLength - length
            }
        }
        val offset = attr(xmp, "MicroVideoOffset")?.toLongOrNull() ?: return null
        return if (offset in 1 until fileLength) fileLength - offset else null
    }

    /** `Prefix:Name="value"` or `<Prefix:Name>value</Prefix:Name>`, whatever the namespace prefix. */
    private fun attr(text: String, name: String): String? =
        Regex("""\b\w+:$name\s*=\s*"([^"]*)"""").find(text)?.groupValues?.get(1)
            ?: Regex("""<\w+:$name>([^<]*)</""").find(text)?.groupValues?.get(1)?.trim()

    /** Samsung: `[data…][directory "SEFH"…][size LE32]["SEFT"]`, each entry pointing back to its data. */
    internal fun fromSamsungTrailer(fileLength: Long, read: Reader): Video? {
        val tail = read.read(fileLength - 8, 8)
        if (tail.size < 8 || String(tail, 4, 4, Charsets.ISO_8859_1) != "SEFT") return null
        val dirSize = le32(tail, 0)
        val dirStart = fileLength - 8 - dirSize
        if (dirSize < 12 || dirStart < 0 || dirSize > 1 shl 20) return null
        val dir = read.read(dirStart, dirSize.toInt())
        if (String(dir, 0, 4, Charsets.ISO_8859_1) != "SEFH") return null
        val count = le32(dir, 8).toInt()
        for (i in 0 until count) {
            val e = 12 + i * 12
            if (e + 12 > dir.size) break
            val back = le32(dir, e + 4)
            val size = le32(dir, e + 8)
            val dataStart = dirStart - back
            if (dataStart < 0 || size <= 0 || dataStart + size > dirStart) continue
            // Entry data: a small header, the entry's name, then the payload.
            val header = read.read(dataStart, minOf(64L, size).toInt())
            val name = "MotionPhoto_Data".toByteArray(Charsets.ISO_8859_1)
            val at = indexOf(header, name)
            if (at < 0) continue
            val start = dataStart + at + name.size
            val video = verified(start, dataStart + size, read) ?: continue
            return video
        }
        return null
    }

    /** The video if an MP4 `ftyp` box starts at [start]; it runs to [end]. */
    private fun verified(start: Long, end: Long, read: Reader): Video? {
        if (start < 0 || end - start < 16) return null
        val box = read.read(start, 8)
        if (box.size < 8 || String(box, 4, 4, Charsets.ISO_8859_1) != "ftyp") return null
        return Video(start, end - start)
    }

    private fun le32(b: ByteArray, at: Int): Long =
        (b[at].toLong() and 0xff) or ((b[at + 1].toLong() and 0xff) shl 8) or
            ((b[at + 2].toLong() and 0xff) shl 16) or ((b[at + 3].toLong() and 0xff) shl 24)

    private fun indexOf(hay: ByteArray, needle: ByteArray): Int {
        outer@ for (i in 0..hay.size - needle.size) {
            for (j in needle.indices) if (hay[i + j] != needle[j]) continue@outer
            return i
        }
        return -1
    }
}
