package app.lelvo.android.viewer

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaDataSource
import android.media.MediaMetadataRetriever
import android.net.Uri
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.dp
import app.lelvo.core.format.ByteRange
import app.lelvo.core.index.LibraryItem
import app.lelvo.core.support.AppLog
import app.lelvo.core.video.VideoNavigation
import app.lelvo.data.media.MediaReader
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext

/**
 * Frames along the timeline, shown above the scrubber while it's dragged (iOS `FrameStrip`). Made once per video,
 * small and at the nearest keyframe, so a cloud video only fetches a little around each one.
 */
@Stable
internal class FrameStrip(private val scope: CoroutineScope) {
    var frames by mutableStateOf<List<ImageBitmap>>(emptyList())
        private set
    private var loadedKey: String? = null
    private var job: Job? = null

    /** Where the frames come from: a file on the phone (or the demo), or a cloud video's role, read and decrypted. */
    sealed interface Source {
        val key: String
        data class Local(val uri: Uri) : Source { override val key get() = uri.toString() }
        data class Cloud(val reader: MediaReader, val item: LibraryItem, val role: String) : Source {
            override val key get() = "${item.id}/$role"
        }
    }

    fun load(context: Context, source: Source, durationSeconds: Double) {
        if (source.key == loadedKey) return
        val times = VideoNavigation.stripTimes(durationSeconds, COUNT)
        if (times.isEmpty()) return
        loadedKey = source.key
        frames = emptyList()
        job?.cancel()
        val started = System.currentTimeMillis()
        job = scope.launch(Dispatchers.IO) {
            val retriever = MediaMetadataRetriever()
            try {
                when (source) {
                    is Source.Local -> retriever.setDataSource(context, source.uri)
                    is Source.Cloud -> retriever.setDataSource(CloudVideoBytes(source.reader, source.item, source.role))
                }
                val made = mutableListOf<Bitmap>()
                for (t in times) {
                    ensureActive()
                    retriever.getScaledFrameAtTime((t * 1_000_000).toLong(), MediaMetadataRetriever.OPTION_CLOSEST_SYNC, 160, 160)?.let(made::add)
                }
                val images = made.map { it.asImageBitmap() }
                withContext(Dispatchers.Main) { frames = images }
                AppLog.info("Video frame strip: ${made.size} of ${times.size} frames in %.1f s".format((System.currentTimeMillis() - started) / 1000.0))
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                // The strip is a help, not a must: the scrubber works without it.
                AppLog.warn("Video frame strip: none", e)
                loadedKey = null
            } finally {
                runCatching { retriever.release() }
            }
        }
    }

    fun cancel() { job?.cancel() }

    companion object { const val COUNT = 8 }
}

/**
 * A cloud video's bytes for `MediaMetadataRetriever`: decrypted ranges from Telegram, read 512 KB at a time, since the
 * retriever asks for many small pieces around each keyframe. Called on the retriever's own thread.
 */
private class CloudVideoBytes(private val reader: MediaReader, private val item: LibraryItem, private val role: String) : MediaDataSource() {
    private val total: Long by lazy { runBlocking { reader.plaintextSize(item, role) } }
    private var blockStart = -1L
    private var block = ByteArray(0)

    override fun getSize(): Long = total

    override fun readAt(position: Long, buffer: ByteArray, offset: Int, size: Int): Int {
        if (position >= total) return -1
        if (size == 0) return 0
        if (position !in blockStart until blockStart + block.size) {
            val start = position - position % BLOCK
            block = runBlocking { reader.read(item, role, ByteRange(start, minOf(total, start + BLOCK))) }
            blockStart = start
        }
        val from = (position - blockStart).toInt()
        val n = minOf(size, block.size - from)
        System.arraycopy(block, from, buffer, offset, n)
        return n
    }

    override fun close() = Unit

    companion object { const val BLOCK = 512L * 1024 }
}

/** The strip, with a white line where the scrubber is. Hidden from TalkBack: the scrubber says the position. */
@Composable
internal fun FrameStripView(frames: List<ImageBitmap>, position: Float, modifier: Modifier = Modifier) {
    Box(modifier.fillMaxWidth().height(44.dp).clearAndSetSemantics { }) {
        Row(Modifier.fillMaxWidth().fillMaxHeight().clip(RoundedCornerShape(6.dp))) {
            frames.forEach { Image(it, null, contentScale = ContentScale.Crop, modifier = Modifier.weight(1f).fillMaxHeight()) }
        }
        Canvas(Modifier.fillMaxWidth().fillMaxHeight()) {
            val w = 3.dp.toPx()
            val x = (size.width * position - w / 2).coerceIn(0f, size.width - w)
            drawRoundRect(Color.Black.copy(alpha = 0.35f), Offset(x - 1, -3.dp.toPx()), Size(w + 2, size.height + 6.dp.toPx()), CornerRadius(2.dp.toPx()))
            drawRoundRect(Color.White, Offset(x, -3.dp.toPx()), Size(w, size.height + 6.dp.toPx()), CornerRadius(2.dp.toPx()))
        }
    }
}
