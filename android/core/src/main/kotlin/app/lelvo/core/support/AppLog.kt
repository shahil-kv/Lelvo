package app.lelvo.core.support

import java.io.File
import java.time.Instant
import java.util.concurrent.Executors

/**
 * Small on-device log (no analytics, never leaves the phone unless the user shares it). Every line is redacted before
 * it is written. Same file, size limit and rotation as the iOS `AppLog`.
 *
 * Lives in `core/` (pure Kotlin) rather than `data/` so the `telegram` module can log through it too. The app calls
 * [install] once at start; lines logged before that are only echoed.
 */
object AppLog {
    enum class Level(val label: String) { INFO("INFO"), WARN("WARN"), ERROR("ERROR") }

    private const val MAX_BYTES = 1_000_000L

    // One writer thread keeps lines in order and file IO off the caller's thread.
    private val writer = Executors.newSingleThreadExecutor { r -> Thread(r, "lelvo.log").apply { isDaemon = true } }

    @Volatile private var dir: File? = null
    @Volatile private var secrets: () -> List<String> = { emptyList() }
    @Volatile private var echo: ((Level, String) -> Unit)? = null

    /**
     * [secrets]: values known to this install that must never appear (api_hash and the like).
     * [echo]: debug builds pass logcat here, like iOS prints to the device console in Debug.
     */
    fun install(dir: File, secrets: () -> List<String>, echo: ((Level, String) -> Unit)? = null) {
        dir.mkdirs()
        this.secrets = secrets
        this.echo = echo
        this.dir = dir
    }

    val file: File? get() = dir?.let { File(it, "lelvo.log") }
    private val oldFile: File? get() = dir?.let { File(it, "lelvo.old.log") }

    fun log(message: String, level: Level = Level.INFO) {
        val clean = Redactor.redact(message, safeSecrets())
        echo?.invoke(level, clean)
        val line = "${Instant.now()} [${level.label}] $clean\n"
        val file = file ?: return
        val old = oldFile ?: return
        writer.execute {
            runCatching {
                if (file.length() > MAX_BYTES) {
                    old.delete()
                    file.renameTo(old)
                }
                file.appendText(line)
            }
        }
    }

    fun info(message: String) = log(message, Level.INFO)
    fun warn(message: String) = log(message, Level.WARN)
    fun error(message: String) = log(message, Level.ERROR)

    /** A failure's kind and message, never its stack: messages from libraries can carry ids. Redacted like any line. */
    fun warn(message: String, error: Throwable) = log("$message: ${describe(error)}", Level.WARN)
    fun error(message: String, error: Throwable) = log("$message: ${describe(error)}", Level.ERROR)

    /** Full log text, redacted again in case secrets changed since lines were written. Waits for pending lines. */
    fun contents(): String = writer.submit<String> {
        listOfNotNull(oldFile, file).filter { it.exists() }.joinToString("") { runCatching { it.readText() }.getOrDefault("") }
    }.get().let { Redactor.redact(it, safeSecrets()) }

    /** Writes the shareable copy to [target] (a cache file); null when it couldn't be written. */
    fun export(target: File): File? = runCatching { target.writeText(contents()); target }.getOrNull()

    /** Waits (up to [ms]) for lines still being written: a crash handler calls it before the process dies. */
    fun flush(ms: Long = 1_000) {
        runCatching { writer.submit {}.get(ms, java.util.concurrent.TimeUnit.MILLISECONDS) }
    }

    fun clear() {
        writer.submit { file?.delete(); oldFile?.delete() }.get()
    }

    private fun safeSecrets(): List<String> = runCatching { secrets() }.getOrDefault(emptyList())

    private fun describe(e: Throwable): String = listOfNotNull(e.javaClass.simpleName, e.message).joinToString(" ")
}
