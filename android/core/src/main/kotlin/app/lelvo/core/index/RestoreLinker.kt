package app.lelvo.core.index

/** What linking needs to know about a photo on this phone: its MediaStore id, name, capture time (ms) and shown size. */
data class AssetKey(val localId: String, val filename: String, val takenAt: Long?, val width: Int, val height: Int)

/**
 * Links restored cloud items to this phone's photos without reading any file (iOS `RestoreLinker`): first by the
 * MediaStore id the caption recorded (`l`, docs/CLOUD_FORMAT.md), then by file name + capture second + pixel size.
 * Each photo and each item is linked at most once. An iPhone's photo ids never match an Android one, so items backed
 * up from an iPhone link by name, second and size only.
 */
object RestoreLinker {
    /** Item id → MediaStore id. */
    fun match(unlinked: List<LibraryItem>, assets: List<AssetKey>): Map<String, String> {
        val links = HashMap<String, String>()
        val used = HashSet<String>()
        val ids = assets.map { it.localId }.toHashSet()
        for (item in unlinked) {
            val id = item.sourceLocalId ?: continue
            if (id in ids && used.add(id)) links[item.id] = id
        }
        val byKey = HashMap<String, String>()
        for (a in assets) {
            if (a.localId in used) continue
            val k = key(a.filename, a.takenAt, a.width, a.height) ?: continue
            byKey.putIfAbsent(k, a.localId)
        }
        for (item in unlinked) {
            if (item.id in links) continue
            val k = key(item.filename, item.createdAt, item.width, item.height) ?: continue
            val id = byKey.remove(k) ?: continue
            if (used.add(id)) links[item.id] = id
        }
        return links
    }

    /** Seconds truncated exactly like the caption `t` field. */
    private fun key(name: String, atMs: Long?, w: Int, h: Int): String? {
        if (atMs == null || name.isEmpty() || w <= 0 || h <= 0) return null
        return "${name.lowercase()}|${Math.floorDiv(atMs, 1000L)}|${w}x$h"
    }
}
