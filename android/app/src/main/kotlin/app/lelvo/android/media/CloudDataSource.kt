package app.lelvo.android.media

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.PlaybackException
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSourceException
import androidx.media3.datasource.DataSpec
import app.lelvo.core.format.ByteRange
import app.lelvo.core.index.LibraryItem
import app.lelvo.data.media.MediaReader
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import java.io.IOException

/**
 * Plays a cloud video straight from Telegram (iOS `StreamingAsset`): the player asks for byte ranges of the
 * plaintext, and [MediaReader] fetches and decrypts only the CGFE chunks they fall in. Reads go a block at a time
 * through one continuous Telegram download that runs ahead of the playhead (`TdFiles.streamRead`), and the reader
 * keeps the last few decrypted chunks, so the player's many small reads cost one download each.
 */
@UnstableApi
class CloudDataSource(private val reader: MediaReader, private val item: LibraryItem, private val role: String) : BaseDataSource(true) {
    private var uri: Uri? = null
    private var position = 0L
    private var remaining = 0L
    private var total = 0L
    private var block: ByteArray? = null
    private var blockStart = 0L
    // The next block downloads while the player reads this one, so Telegram's round trip doesn't stall playback
    // (iOS keeps a continuous download window for the same reason).
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var ahead: Pair<Long, Deferred<ByteArray>>? = null

    override fun open(dataSpec: DataSpec): Long {
        transferInitializing(dataSpec)
        uri = dataSpec.uri
        total = fetch { reader.plaintextSize(item, role) }
        if (dataSpec.position > total) throw DataSourceException(PlaybackException.ERROR_CODE_IO_READ_POSITION_OUT_OF_RANGE)
        position = dataSpec.position
        remaining = if (dataSpec.length != C.LENGTH_UNSET.toLong()) minOf(dataSpec.length, total - position) else total - position
        transferStarted(dataSpec)
        return remaining
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (length == 0) return 0
        if (remaining == 0L) return C.RESULT_END_OF_INPUT
        var data = block
        if (data == null || position < blockStart || position >= blockStart + data.size) {
            blockStart = position / BLOCK * BLOCK
            val start = blockStart
            val waiting = ahead?.takeIf { it.first == start }?.second
            if (waiting == null) ahead?.second?.cancel()
            ahead = null
            data = fetch { waiting?.await() ?: readBlock(start) }
            if (data.isEmpty()) throw DataSourceException(PlaybackException.ERROR_CODE_IO_UNSPECIFIED)
            block = data
            val next = start + BLOCK
            if (next < total) ahead = next to scope.async { readBlock(next) }
        }
        val from = (position - blockStart).toInt()
        val n = minOf(length.toLong(), remaining, (data.size - from).toLong()).toInt()
        System.arraycopy(data, from, buffer, offset, n)
        position += n
        remaining -= n
        bytesTransferred(n)
        return n
    }

    private suspend fun readBlock(start: Long) = reader.read(item, role, ByteRange(start, minOf(total, start + BLOCK)), streaming = true)

    override fun getUri(): Uri? = uri

    override fun close() {
        ahead?.second?.cancel()
        ahead = null
        if (uri != null) { uri = null; block = null; transferEnded() }
    }

    /** The player's loader thread waits here; a failed read becomes the IOException Media3 retries or reports. */
    private fun <T> fetch(work: suspend () -> T): T = try {
        runBlocking { work() }
    } catch (e: IOException) {
        throw e
    } catch (e: Exception) {
        throw DataSourceException(e, PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED)
    }

    class Factory(private val reader: MediaReader, private val item: LibraryItem, private val role: String) : DataSource.Factory {
        override fun createDataSource(): DataSource = CloudDataSource(reader, item, role)
    }

    private companion object { const val BLOCK = 1L shl 20 }
}
