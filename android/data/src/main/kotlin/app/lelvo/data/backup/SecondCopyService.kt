package app.lelvo.data.backup

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import app.lelvo.core.backup.SecondCopy
import app.lelvo.core.index.ItemStatus
import app.lelvo.core.support.AppLog
import app.lelvo.data.index.LibraryStore
import app.lelvo.data.media.MediaReader
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.io.File
import java.time.ZoneId
import kotlin.coroutines.coroutineContext

/**
 * Keeps a second copy of the library in a folder the user picks (a USB drive, an SD card, a NAS through a documents
 * app), as the Mac's `SecondCopyService` does: `Year/Month/name`, a manifest in the folder, nothing ever deleted
 * there. Files are written under a temporary name and renamed when complete, so a short file is never left behind.
 */
class SecondCopyService(context: Context, private val store: LibraryStore, private val reader: MediaReader) {
    private val app = context.applicationContext
    private val prefs = app.getSharedPreferences("secondCopy", Context.MODE_PRIVATE)
    private val resolver = app.contentResolver
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val work = File(app.cacheDir, "SecondCopy")

    data class State(
        val folderName: String? = null,
        val running: Boolean = false,
        val done: Int = 0,
        val total: Int = 0,
        val inFolder: Int = 0,
        val bytesLeft: Long = 0,
        val failed: Int = 0,
        val removedFromLibrary: Int = 0,
        val message: String? = null,
        val lastRunAt: Long? = null,
    )

    private val _state = MutableStateFlow(State(folderName = folder?.let(::displayName), lastRunAt = prefs.getLong(LAST_RUN, 0).takeIf { it > 0 }))
    val state: StateFlow<State> = _state
    private var job: Job? = null

    val folder: Uri? get() = prefs.getString(FOLDER, null)?.let(Uri::parse)?.takeIf { uri ->
        resolver.persistedUriPermissions.any { it.uri == uri && it.isWritePermission }
    }

    /** Keeps access to the chosen folder across restarts. */
    fun choose(tree: Uri) {
        resolver.takePersistableUriPermission(tree, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        prefs.edit().putString(FOLDER, tree.toString()).apply()
        _state.update { it.copy(folderName = displayName(tree), message = null) }
        AppLog.info("Second copy: folder chosen")
    }

    /** Stops copying; the folder keeps its files. */
    fun turnOff() {
        job?.cancel()
        folder?.let { uri -> runCatching { resolver.releasePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION) } }
        prefs.edit().remove(FOLDER).apply()
        _state.value = State()
        AppLog.info("Second copy turned off; the folder keeps its files")
    }

    fun cancel() { job?.cancel() }

    fun syncNow() {
        if (job?.isActive == true) return
        job = scope.launch { pass() }
    }

    private suspend fun pass() {
        val tree = folder ?: run { _state.update { it.copy(message = "Choose a folder first.") }; return }
        val root = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        _state.update { it.copy(running = true, done = 0, failed = 0, message = "Looking at the folder…") }
        var copied = 0; var failed = 0
        try {
            val disk = listTree(tree, root)
            var manifest = read(tree, root)
            val items = store.items(ItemStatus.BackedUp).filter { it.parts["o"]?.isNotEmpty() == true }
            val plan = SecondCopy.plan(items, manifest, ZoneId.systemDefault()) { disk[it]?.second }
            for (f in plan.toAdopt) manifest = manifest.record(f, f.size)
            if (plan.toAdopt.isNotEmpty()) write(tree, root, disk, manifest)
            val inFolder = plan.upToDate + plan.toAdopt.size
            AppLog.info("Second copy: ${plan.toCopy.size} files to copy, $inFolder already there")
            _state.update {
                it.copy(total = plan.toCopy.size, inFolder = inFolder, bytesLeft = plan.bytesToCopy, removedFromLibrary = plan.removedFromLibrary,
                    message = if (plan.toCopy.isEmpty()) "Everything is in the folder." else null)
            }
            val byId = items.associateBy { it.id }
            work.mkdirs()
            for (file in plan.toCopy) {
                coroutineContext.ensureActive()
                if (!SecondCopy.isSafe(file.path)) { AppLog.warn("Second copy: skipped a file whose path leaves the folder"); continue }
                val item = byId[file.itemId] ?: continue
                val tmp = File(work, "${System.nanoTime()}.part")
                try {
                    reader.download(item, file.role, tmp)
                    val written = tmp.length()
                    if (file.size > 0 && written != file.size) AppLog.warn("Second copy: a file came out at $written bytes, the index says ${file.size}")
                    put(tree, root, disk, file.path, tmp)
                    manifest = manifest.record(file, written)
                    write(tree, root, disk, manifest)
                    copied++
                    _state.update { it.copy(done = copied + failed, inFolder = it.inFolder + 1, bytesLeft = maxOf(0, it.bytesLeft - file.size)) }
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    failed++
                    AppLog.warn("Second copy: a file couldn't be copied: ${e::class.simpleName}")
                    _state.update { it.copy(done = copied + failed, failed = failed) }
                } finally {
                    tmp.delete()
                }
            }
            prefs.edit().putLong(LAST_RUN, System.currentTimeMillis()).apply()
            AppLog.info("Second copy pass finished: $copied copied, $failed failed")
            _state.update { it.copy(running = false, lastRunAt = System.currentTimeMillis(), message = if (failed > 0) "$failed couldn't be copied. Tap Copy now to try again." else it.message) }
        } catch (e: CancellationException) {
            _state.update { it.copy(running = false, message = "Stopped. Tap Copy now to continue.") }
            throw e
        } catch (e: Exception) {
            AppLog.warn("Second copy: the folder can't be read: ${e::class.simpleName}")
            _state.update { it.copy(running = false, message = "Lelvo can't reach the folder. Connect the drive or choose the folder again.") }
        }
    }

    /** Every file under the folder: relative path → (document uri, size). Lelvo's folders are two deep. */
    private fun listTree(tree: Uri, root: Uri): MutableMap<String, Pair<Uri, Long>> {
        val out = HashMap<String, Pair<Uri, Long>>()
        fun walk(docId: String, prefix: String, depth: Int) {
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, docId)
            resolver.query(children, arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE, Document.COLUMN_SIZE), null, null, null)?.use { c ->
                while (c.moveToNext()) {
                    val id = c.getString(0); val name = c.getString(1) ?: continue
                    val path = prefix + name
                    if (c.getString(2) == Document.MIME_TYPE_DIR) {
                        out[path + "/"] = DocumentsContract.buildDocumentUriUsingTree(tree, id) to -1L
                        if (depth < 3) walk(id, "$path/", depth + 1)
                    } else {
                        out[path] = DocumentsContract.buildDocumentUriUsingTree(tree, id) to (if (c.isNull(3)) 0L else c.getLong(3))
                    }
                }
            }
        }
        walk(DocumentsContract.getDocumentId(root), "", 0)
        return out
    }

    private fun read(tree: Uri, root: Uri): SecondCopy.Manifest {
        val uri = listTree(tree, root)[SecondCopy.Manifest.FILE_NAME]?.first ?: return SecondCopy.Manifest()
        return resolver.openInputStream(uri)?.use { SecondCopy.Manifest.decode(it.readBytes().decodeToString()) } ?: SecondCopy.Manifest()
    }

    private fun write(tree: Uri, root: Uri, disk: MutableMap<String, Pair<Uri, Long>>, manifest: SecondCopy.Manifest) {
        val tmp = File(work.apply { mkdirs() }, "manifest.json").apply { writeText(manifest.encode()) }
        try { put(tree, root, disk, SecondCopy.Manifest.FILE_NAME, tmp, replace = true) } finally { tmp.delete() }
    }

    /** Writes [source] to [path] under a temporary name, then renames it. Never replaces a file unless [replace]. */
    private fun put(tree: Uri, root: Uri, disk: MutableMap<String, Pair<Uri, Long>>, path: String, source: File, replace: Boolean = false) {
        val parts = path.split('/')
        var parent = root
        var prefix = ""
        for (dir in parts.dropLast(1)) {
            prefix += "$dir/"
            parent = disk[prefix]?.first ?: DocumentsContract.createDocument(resolver, parent, Document.MIME_TYPE_DIR, dir)
                ?.also { disk[prefix] = it to -1L } ?: throw java.io.IOException("Couldn't make a folder")
        }
        val name = parts.last()
        disk[path]?.let { (existing, _) ->
            if (!replace) throw java.io.IOException("A file is already there")
            resolver.openOutputStream(existing, "wt")?.use { out -> source.inputStream().use { it.copyTo(out) } }
            disk[path] = existing to source.length()
            return
        }
        val partial = DocumentsContract.createDocument(resolver, parent, "application/octet-stream", "$name.lelvo-partial")
            ?: throw java.io.IOException("Couldn't create the file")
        try {
            resolver.openOutputStream(partial, "w")?.use { out -> source.inputStream().use { it.copyTo(out, 1 shl 20) } }
                ?: throw java.io.IOException("Couldn't write the file")
            val final = DocumentsContract.renameDocument(resolver, partial, name) ?: partial
            disk[path] = final to source.length()
        } catch (e: Exception) {
            runCatching { DocumentsContract.deleteDocument(resolver, partial) }
            throw e
        }
    }

    private fun displayName(tree: Uri): String = runCatching {
        val doc = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        resolver.query(doc, arrayOf(Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { if (it.moveToFirst()) it.getString(0) else null }
    }.getOrNull() ?: "Chosen folder"

    private companion object {
        const val FOLDER = "folder"
        const val LAST_RUN = "lastRunAt"
    }
}
