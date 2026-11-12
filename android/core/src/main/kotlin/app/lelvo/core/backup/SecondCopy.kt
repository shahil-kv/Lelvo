package app.lelvo.core.backup

import app.lelvo.core.format.FieldException
import app.lelvo.core.format.JsonFields
import app.lelvo.core.format.JsonIO
import app.lelvo.core.index.ItemKind
import app.lelvo.core.index.LibraryItem
import kotlinx.serialization.json.JsonObject
import java.time.Instant
import java.time.ZoneId

/**
 * "Keep a second copy" (iOS/Mac `SecondCopy`): which files of the library belong in the user's own folder, where they
 * go (`Year/Month/filename`), and which are still missing. What was copied is recorded per item and role in a
 * manifest kept in the folder, so a drive that comes back is never guessed from file names. Nothing is ever deleted
 * from the folder.
 */
object SecondCopy {
    data class File(val itemId: String, val role: String, val path: String, val size: Long, val date: Long?) {
        val key: String get() = Manifest.key(itemId, role)
    }

    data class Entry(val path: String, val size: Long)

    /** Item ids, roles, relative paths and sizes only; a hidden file in the folder, so it travels with the drive. */
    data class Manifest(val files: Map<String, Entry> = emptyMap(), val version: Int = 1) {
        fun record(file: File, size: Long) = copy(files = files + (file.key to Entry(file.path, size)))
        val itemIds: Set<String> get() = files.keys.map { it.substringBefore('/') }.toSet()

        fun encode(): String = JsonIO.obj(
            "files" to JsonObject(files.mapValues { (_, e) -> JsonIO.obj("path" to JsonIO.str(e.path), "size" to JsonIO.num(e.size)) }),
            "version" to JsonIO.num(version),
        ).toString()

        companion object {
            const val FILE_NAME = ".lelvo-second-copy.json"
            fun key(itemId: String, role: String) = "$itemId/$role"

            /** The same JSON the Mac writes. Unreadable gives an empty manifest: files are then adopted by size. */
            fun decode(text: String): Manifest = try {
                val f = JsonFields(JsonIO.parseObject(text) ?: throw FieldException("manifest"))
                val files = (f.objOrNull("files") ?: JsonObject(emptyMap())).mapNotNull { (k, v) ->
                    val e = JsonFields(v as? JsonObject ?: return@mapNotNull null)
                    k to Entry(e.string("path"), e.long("size"))
                }.toMap()
                Manifest(files, f.intOrNull("version") ?: 1)
            } catch (_: Exception) {
                Manifest()
            }
        }
    }

    data class Plan(
        val toCopy: List<File> = emptyList(),
        val toAdopt: List<File> = emptyList(),
        val upToDate: Int = 0,
        val upToDateBytes: Long = 0,
        val removedFromLibrary: Int = 0,
    ) {
        val bytesToCopy: Long get() = toCopy.sumOf { it.size }
    }

    /** Owner of a path whose file was changed outside Lelvo: it's taken, whoever the manifest says wrote it. */
    const val CHANGED_OUTSIDE_LELVO = "changed-outside-lelvo"

    fun wanted(item: LibraryItem, zone: ZoneId): List<File> {
        val folder = monthFolder(item.createdAt, zone)
        val out = mutableListOf(File(item.id, "o", folder + sanitized(item.filename), item.fileSize, item.createdAt))
        val base = item.filename.substringBeforeLast('.', item.filename)
        if (item.kind == ItemKind.LivePhoto && item.parts["pv"]?.isNotEmpty() == true) {
            out += File(item.id, "pv", folder + sanitized(item.pairedVideoName ?: "$base.MOV"), item.pairedVideoSize ?: 0, item.createdAt)
        }
        if (item.hasEdit && item.parts["e"]?.isNotEmpty() == true) {
            val ext = (item.editedName ?: item.filename).substringAfterLast('.', "")
            out += File(item.id, "e", folder + sanitized(if (ext.isEmpty()) "$base (edited)" else "$base (edited).$ext"), item.editedSize ?: 0, item.createdAt)
        }
        return out
    }

    fun plan(items: List<LibraryItem>, manifest: Manifest, zone: ZoneId, sizeOnDisk: (String) -> Long?): Plan {
        val toCopy = ArrayList<File>(); val toAdopt = ArrayList<File>()
        var upToDate = 0; var upToDateBytes = 0L
        // Paths the manifest already gives to an item, so a new item never takes one.
        val claimed = HashMap<String, String>()
        for ((key, entry) in manifest.files) if (isSafe(entry.path)) claimed[entry.path.lowercase()] = key
        val present = items.map { it.id }.toSet()
        val removed = (manifest.itemIds - present).size
        for (item in items.sortedWith(compareBy<LibraryItem>({ it.createdAt ?: Long.MIN_VALUE }, { it.id }))) {
            for (wantedFile in wanted(item, zone)) {
                var file = wantedFile
                // The manifest sits where others can write: a path that could leave the folder is ignored.
                val entry = manifest.files[file.key]?.takeIf { isSafe(it.path) }
                if (entry != null) {
                    file = file.copy(path = entry.path)
                    val onDisk = sizeOnDisk(entry.path)
                    if (onDisk == null) { toCopy += file; continue }
                    if (onDisk == entry.size) { upToDate++; upToDateBytes += onDisk; continue }
                    // Changed by something else: left alone, and the copy goes to a new path.
                    val others = HashMap(claimed).apply { put(entry.path.lowercase(), CHANGED_OUTSIDE_LELVO) }
                    file = file.copy(path = freePath(file, others, sizeOnDisk))
                    claimed[file.path.lowercase()] = file.key
                    toCopy += file
                    continue
                }
                file = file.copy(path = freePath(file, claimed, sizeOnDisk))
                claimed[file.path.lowercase()] = file.key
                if (file.size > 0 && sizeOnDisk(file.path) == file.size) toAdopt += file else toCopy += file
            }
        }
        return Plan(toCopy, toAdopt, upToDate, upToDateBytes, removed)
    }

    /** Relative, with no `.`, `..` or empty parts. The app also refuses to write outside the chosen folder. */
    fun isSafe(path: String): Boolean {
        if (path.isEmpty() || path.startsWith("/") || path.startsWith("~") || '\\' in path || '\u0000' in path) return false
        return path.split('/').all { it.isNotEmpty() && it != "." && it != ".." }
    }

    /** The wanted path, or `name-<id>.ext` when another item or another file has it. Case-insensitive, like most drives. */
    fun freePath(file: File, claimed: Map<String, String>, sizeOnDisk: (String) -> Long?): String {
        fun taken(path: String): Boolean {
            claimed[path.lowercase()]?.let { return it != file.key }
            sizeOnDisk(path)?.let { return file.size == 0L || it != file.size }
            return false
        }
        if (!taken(file.path)) return file.path
        val slash = file.path.lastIndexOf('/')
        val name = file.path.substring(slash + 1)
        val dot = name.lastIndexOf('.')
        val stem = file.path.substring(0, slash + 1) + if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot + 1) else ""
        val suffix = if (file.role == "o") file.itemId.take(6) else "${file.itemId.take(6)}-${file.role}"
        fun named(n: Int?) = stem + "-" + suffix + (n?.let { "-$it" } ?: "") + if (ext.isEmpty()) "" else ".$ext"
        var candidate = named(null)
        var n = 2
        while (taken(candidate)) candidate = named(n++)
        return candidate
    }

    fun monthFolder(date: Long?, zone: ZoneId): String {
        val d = Instant.ofEpochMilli(date ?: 0).atZone(zone)
        return "%04d/%02d/".format(d.year, d.monthValue)
    }

    /** Safe on Android, Windows-formatted drives and NAS shares. */
    fun sanitized(name: String): String {
        val cleaned = name.map { if (it in "/\\:?%*|\"<>\n\r") '_' else it }.joinToString("").trim()
        val visible = if (cleaned.startsWith(".")) "_" + cleaned.drop(1) else cleaned
        return visible.ifEmpty { "file" }
    }
}
