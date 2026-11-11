package app.lelvo.data.media

import android.content.Context
import android.net.Uri
import app.lelvo.core.media.MotionPhoto
import app.lelvo.core.support.AppLog
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer

/**
 * The video inside an Android Motion Photo, on this phone or a cloud original, copied out to a small cache file the
 * player reads (a few MB). Players can't read a byte range of a content URI on every Android version, and the copy
 * makes a second play instant. The photo itself is never changed.
 */
class MotionVideos(context: Context) {
    private val resolver = context.contentResolver
    private val dir = File(context.cacheDir, "Motion").apply { mkdirs() }

    /** The motion of [uri] as a file, or null when it isn't a Motion Photo. [key] names the cache entry. */
    suspend fun video(uri: Uri, key: String): File? = withContext(Dispatchers.IO) {
        val out = File(dir, "${key.filter { it.isLetterOrDigit() || it == '_' }}.mp4")
        if (out.length() > 0) return@withContext out
        try {
            resolver.openFileDescriptor(uri, "r")?.use { pfd ->
                FileInputStream(pfd.fileDescriptor).channel.use { ch ->
                    val length = ch.size()
                    val video = MotionPhoto.find(length) { offset, n ->
                        val buf = ByteBuffer.allocate(minOf(n.toLong(), length - offset).coerceAtLeast(0).toInt())
                        while (buf.hasRemaining()) { if (ch.read(buf, offset + buf.position()) <= 0) break }
                        buf.array().copyOf(buf.position())
                    } ?: return@withContext null
                    val tmp = File(dir, "${out.name}.part")
                    tmp.outputStream().channel.use { dst ->
                        var done = 0L
                        while (done < video.length) {
                            val n = ch.transferTo(video.start + done, video.length - done, dst)
                            if (n <= 0) break
                            done += n
                        }
                        if (done != video.length) { tmp.delete(); return@withContext null }
                    }
                    if (!tmp.renameTo(out)) { tmp.delete(); return@withContext null }
                    trim()
                    out
                }
            }
        } catch (e: Exception) {
            if (e is kotlinx.coroutines.CancellationException) throw e
            AppLog.warn("Motion photo: couldn't read the video", e)
            null
        }
    }

    /** Keeps the newest 30 (about 100 MB at most); older ones are copied out again when opened. */
    private fun trim() {
        dir.listFiles { f -> f.extension == "mp4" }?.sortedByDescending { it.lastModified() }?.drop(30)?.forEach { it.delete() }
    }

    fun clear() { dir.listFiles()?.forEach { it.delete() } }
}
