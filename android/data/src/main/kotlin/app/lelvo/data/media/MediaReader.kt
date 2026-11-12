package app.lelvo.data.media

import app.lelvo.core.crypto.CgfeRandomReader
import app.lelvo.core.crypto.DecryptedChunkCache
import app.lelvo.core.crypto.FileCrypto
import app.lelvo.core.format.ByteRange
import app.lelvo.core.format.PartLayout
import app.lelvo.core.index.LibraryItem
import app.lelvo.core.index.RemoteFile
import app.lelvo.data.LibraryService
import app.lelvo.telegram.AuthStep
import app.lelvo.telegram.TdClient
import app.lelvo.telegram.TdFiles
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.drinkless.tdlib.TdApi
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.ConcurrentHashMap

/** What the user reads when a cloud file can't be shown (iOS `MediaReader.ReadError`). */
class MediaException(message: String) : Exception(message) {
    companion object {
        val missing = MediaException("This file is no longer in your Telegram channel.")
        val locked = MediaException("Unlock the library with your passphrase to view encrypted items.")
        val offline = MediaException("Couldn't reach Telegram. Check your connection and try again.")
    }
}

/**
 * Random-access reads of cloud resources (iOS `MediaReader`): plaintext ranges → CGFE chunks → split parts
 * (docs/CLOUD_FORMAT.md §5, §6.2) → TDLib ranged downloads. Only the chunks a read needs are fetched and decrypted.
 */
class MediaReader(private val files: TdFiles, private val library: LibraryService, private val td: TdClient) {
    /** Message id → a remote id that works this session (the stored one, or a fresh one from the message). */
    private val remoteIds = ConcurrentHashMap<Long, String>()
    /** item/role → CGFE header. */
    private val headers = ConcurrentHashMap<String, ByteArray>()
    private val chunks = DecryptedChunkCache()

    fun parts(item: LibraryItem, role: String): List<RemoteFile> = item.parts[role].orEmpty()

    /** Size of the stored stream (ciphertext), summed over parts. */
    fun streamSize(item: LibraryItem, role: String): Long = parts(item, role).sumOf { it.size }

    /** Cold start: waits for the Telegram session instead of failing the tile or the viewer. */
    suspend fun waitUntilReady() {
        if (td.auth.value == AuthStep.Ready) return
        withTimeoutOrNull(30_000) { td.auth.first { it == AuthStep.Ready } } ?: throw MediaException.offline
    }

    /**
     * The stored remote id usually works. A file reference can expire, though, and then the message has the current
     * one (iOS looks every file up through its message; this saves that round trip when it isn't needed).
     */
    private suspend fun remoteId(part: RemoteFile): String {
        remoteIds[part.messageId]?.let { return it }
        val id = if (part.fileId.isNotEmpty() && runCatching { files.file(part.fileId) }.isSuccess) part.fileId else {
            val chatId = library.chatId ?: throw MediaException.missing
            files.ensureChat(chatId)
            val message = runCatching { td.send(TdApi.GetMessage(chatId, part.messageId)) }.getOrNull() ?: throw MediaException.missing
            (message.content as? TdApi.MessageDocument)?.document?.document?.remote?.id ?: throw MediaException.missing
        }
        remoteIds[part.messageId] = id
        return id
    }

    /**
     * Raw stored bytes for [range], across split parts. [streaming] reads through the continuous download the video
     * player keeps running ahead (iOS `streamRead`); a fast version (`sp`) has its index first, so it never needs
     * small reads elsewhere in the file.
     */
    suspend fun readStream(item: LibraryItem, role: String, range: ByteRange, streaming: Boolean = false): ByteArray {
        val ps = parts(item, role)
        if (ps.isEmpty()) throw MediaException.missing
        val partSize = if (ps.size > 1) ps[0].size else maxOf(ps[0].size, 1)
        val layout = PartLayout(partSize, ps.sumOf { it.size })
        suspend fun get(id: String, offset: Long, length: Long) =
            if (streaming) files.streamRead(id, offset, length, smallReads = role != "sp") else files.read(id, offset, length)
        val segments = layout.segments(range)
        if (segments.size == 1) {
            val s = segments[0]
            return get(remoteId(ps[s.part]), s.offset, s.length)
        }
        val out = java.io.ByteArrayOutputStream(range.length.toInt())
        for (s in segments) out.write(get(remoteId(ps[s.part]), s.offset, s.length))
        return out.toByteArray()
    }

    private suspend fun reader(item: LibraryItem, role: String): CgfeRandomReader {
        val master = library.keys?.master ?: throw MediaException.locked
        val key = "${item.id}/$role"
        val header = headers[key] ?: readStream(item, role, ByteRange(0, FileCrypto.HEADER_LENGTH.toLong())).also { headers[key] = it }
        return CgfeRandomReader(header, streamSize(item, role), master)
    }

    /** Plaintext size of a resource. */
    suspend fun plaintextSize(item: LibraryItem, role: String): Long =
        if (item.encrypted) reader(item, role).layout.plaintextSize else streamSize(item, role)

    /** Plaintext bytes for [range], decrypting only the chunks needed. [streaming]: for the video player. */
    suspend fun read(item: LibraryItem, role: String, range: ByteRange, streaming: Boolean = false): ByteArray {
        if (!item.encrypted) return readStream(item, role, range, streaming)
        val r = reader(item, role)
        return r.read(range, chunks, "${item.id}/$role") { cipher -> readStream(item, role, cipher, streaming) }
    }

    /** Writes the whole plaintext resource to [destination] in 8 MiB steps (photos, sharing, saving). */
    suspend fun download(item: LibraryItem, role: String, destination: File, progress: (Float) -> Unit = {}) = withContext(Dispatchers.IO) {
        destination.parentFile?.mkdirs()
        // A file stored in one message (every photo, most short videos) comes down in one TDLib download, which
        // fetches its pieces in parallel; the reads below then come from the phone. Ranged reads cost a round trip
        // each, and the header one more (iOS reads ranges here; this is faster).
        parts(item, role).singleOrNull()?.takeIf { it.size <= WHOLE_LIMIT }?.let { files.download(remoteId(it), priority = 32) }
        val total = plaintextSize(item, role)
        FileOutputStream(destination).use { out ->
            var offset = 0L
            while (offset < total) {
                val data = read(item, role, ByteRange(offset, minOf(total, offset + STEP)))
                if (data.isEmpty()) break
                out.write(data)
                offset += data.size
                progress(offset.toFloat() / maxOf(total, 1))
            }
            if (offset != total) throw MediaException.missing
        }
        // Telegram's copy of the ciphertext isn't needed once the plaintext is cached.
        for (p in parts(item, role)) remoteIds[p.messageId]?.let { files.deleteLocalCopy(it) }
    }

    /**
     * The encrypted thumbnail (role `t`, one small file), downloaded whole and decrypted: one trip to Telegram per
     * tile. Reading it through ranges took three (iOS learned this from slow, empty grids).
     */
    suspend fun thumbnail(item: LibraryItem): ByteArray = withContext(Dispatchers.IO) {
        val master = library.keys?.master ?: throw MediaException.locked
        val part = parts(item, "t").singleOrNull() ?: throw MediaException.missing
        val id = remoteId(part)
        val cipher = files.download(id, priority = 8).readBytes()
        files.deleteLocalCopy(id)
        FileCrypto.decrypt(cipher, master)
    }

    suspend fun telegramStorageBytes(): Long = files.storageBytes()
    suspend fun trimTelegramFiles(maxBytes: Long) = files.trim(maxBytes)
    suspend fun clearTelegramFiles() {
        files.clearAll()
        forgetCaches()
    }

    fun forgetCaches() {
        remoteIds.clear()
        headers.clear()
        chunks.removeAll()
    }

    private companion object {
        const val STEP = 8L shl 20
        const val WHOLE_LIMIT = 64L shl 20
    }
}
