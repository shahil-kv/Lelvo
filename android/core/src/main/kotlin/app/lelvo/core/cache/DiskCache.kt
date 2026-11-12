package app.lelvo.core.cache

import java.io.File

/**
 * A size-capped folder of files, least recently used removed first (iOS `LRUDiskCache`). A file's modification time
 * is its last use, so the order survives restarts without a manifest. Lives in the app's cache folder, which Android
 * may also clear; losing it only costs a download.
 */
class DiskCache(private val dir: File, private val capacity: () -> Long) {
    init { dir.mkdirs() }

    /** File names are the key made safe; keys are ids and roles, never names a person chose. */
    private fun file(key: String, ext: String): File = File(dir, key.replace(Regex("[^A-Za-z0-9._-]"), "_") + "." + ext)

    /** The cached file, marked as just used; null when it isn't cached. */
    @Synchronized
    fun get(key: String, ext: String): File? {
        val f = file(key, ext)
        if (!f.isFile || f.length() == 0L) return null
        f.setLastModified(System.currentTimeMillis())
        return f
    }

    /** Moves [source] in under [key] (or copies it when a move isn't possible), then trims to the capacity. */
    @Synchronized
    fun put(key: String, ext: String, source: File): File {
        val f = file(key, ext)
        f.delete()
        if (!source.renameTo(f)) { source.copyTo(f, overwrite = true); source.delete() }
        f.setLastModified(System.currentTimeMillis())
        trim(keep = f)
        return f
    }

    @Synchronized
    fun put(key: String, ext: String, data: ByteArray): File {
        val tmp = File(dir, ".tmp-${System.nanoTime()}")
        tmp.writeBytes(data)
        return put(key, ext, tmp)
    }

    val totalBytes: Long @Synchronized get() = dir.listFiles()?.sumOf { it.length() } ?: 0L

    @Synchronized
    fun clear() { dir.listFiles()?.forEach { it.delete() } }

    /** After the limit was lowered (Settings → Storage): oldest first until the folder fits. */
    @Synchronized
    fun trimToCapacity() = trim(keep = null)

    /** Oldest first until the folder fits; the file just stored stays even if it alone is bigger. */
    private fun trim(keep: File?) {
        val all = dir.listFiles()?.filter { it.isFile } ?: return
        var total = all.sumOf { it.length() }
        val cap = capacity()
        if (total <= cap) return
        for (f in all.sortedBy { it.lastModified() }) {
            if (total <= cap) break
            if (f == keep) continue
            total -= f.length()
            f.delete()
        }
    }
}
