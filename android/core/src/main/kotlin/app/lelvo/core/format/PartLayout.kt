package app.lelvo.core.format

/** Bytes `start` up to, not including, `endExclusive`. */
data class ByteRange(val start: Long, val endExclusive: Long) {
    val length: Long get() = maxOf(0, endExclusive - start)
    val isEmpty: Boolean get() = endExclusive <= start
}

/** Maps a continuous stream onto fixed-size parts (docs/CLOUD_FORMAT.md §5). */
class PartLayout(partSize: Long, totalSize: Long) {
    val partSize: Long = maxOf(1, partSize)
    val totalSize: Long = maxOf(0, totalSize)

    val partCount: Int get() = maxOf(1L, (totalSize + partSize - 1) / partSize).toInt()
    val isSplit: Boolean get() = partCount > 1

    fun sizeOfPart(index: Int): Long = minOf(partSize, totalSize - index * partSize)

    data class Segment(val part: Int, val offset: Long, val length: Long)

    /** Splits a stream range into per-part segments; a range crossing a part boundary is served from both parts. */
    fun segments(range: ByteRange): List<Segment> {
        val out = ArrayList<Segment>()
        var pos = maxOf(0, range.start)
        val end = minOf(totalSize, range.endExclusive)
        while (pos < end) {
            val part = (pos / partSize).toInt()
            val offset = pos - part * partSize
            val length = minOf(end - pos, partSize - offset)
            out.add(Segment(part, offset, length))
            pos += length
        }
        return out
    }

    override fun equals(other: Any?): Boolean = other is PartLayout && partSize == other.partSize && totalSize == other.totalSize
    override fun hashCode(): Int = partSize.hashCode() * 31 + totalSize.hashCode()
    override fun toString(): String = "PartLayout(partSize=$partSize, totalSize=$totalSize)"

    companion object {
        const val MIB = 1L shl 20
        const val STANDARD_LIMIT = 2000 * MIB
        const val PREMIUM_LIMIT = 4000 * MIB

        /** Part size for an account upload limit: limit − 1 MiB, rounded down to whole MiB. */
        fun partSize(limit: Long): Long = ((limit - MIB) / MIB) * MIB

        /**
         * The layout for uploading `size` bytes. A limit too small to cut whole-MiB parts from (TDLib gave no usable
         * option) falls back to the standard 2,000 MiB, as §5 says.
         */
        fun forUpload(size: Long, limit: Long): PartLayout {
            val usable = if (limit >= 2 * MIB) limit else STANDARD_LIMIT
            return if (size > usable) PartLayout(partSize(usable), size) else PartLayout(maxOf(size, 1), size)
        }
    }
}
