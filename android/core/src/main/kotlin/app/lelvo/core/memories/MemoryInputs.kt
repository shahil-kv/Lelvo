package app.lelvo.core.memories

import app.lelvo.core.index.GalleryEntry

/**
 * The part of a timeline entry that memories are made from. Upload status is left out: a backup changes it every
 * second or two, and rebuilding memories for a whole library on each of those froze the screen.
 * A phone photo's own place is not here. Search reads that and bumps its revision, which forces a rebuild.
 */
data class MemoryInput(
    val id: String,
    val date: Long,
    val latitude: Double?,
    val longitude: Double?,
    /** A screenshot. Receipts and documents come from search, with its revision. */
    val utility: Boolean,
)

object MemoryInputs {
    fun of(entries: List<GalleryEntry>): List<MemoryInput> = entries.mapNotNull { e ->
        val date = e.date ?: return@mapNotNull null
        if (e.isVideo) return@mapNotNull null
        val lat = e.item?.latitude
        val lon = e.item?.longitude
        val placed = lat != null && lon != null && !(lat == 0.0 && lon == 0.0)
        MemoryInput(e.id, date, if (placed) lat else null, if (placed) lon else null, e.asset?.bucketName == "Screenshots")
    }

    /** [previous] null is the first build. [forced] is place names, things in photos, or a memory type switched. */
    fun changed(previous: List<MemoryInput>?, next: List<MemoryInput>, forced: Boolean): Boolean {
        if (forced || previous == null) return true
        return previous != next
    }
}
