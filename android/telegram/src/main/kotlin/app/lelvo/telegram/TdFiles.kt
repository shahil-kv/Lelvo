package app.lelvo.telegram

import app.lelvo.core.support.AppLog
import app.lelvo.core.session.TelegramErrors
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.drinkless.tdlib.TdApi
import java.io.File
import java.io.RandomAccessFile
import java.util.concurrent.ConcurrentHashMap

/**
 * Reading the library channel: its document messages, whole files and byte ranges (iOS `TDService` history,
 * `download` and `streamRead`). Read-only: nothing here sends, edits or deletes a message.
 */
class TdFiles(private val td: TdClient) {
    private val loadedChats = ConcurrentHashMap.newKeySet<Long>()
    // TDLib runs one download per file and cancels the other ("Canceled by another downloadFile request"): one gate
    // per file, as iOS does.
    private val gates = ConcurrentHashMap<Int, Mutex>()

    /**
     * TDLib only knows chats it loaded in this session; after a restart the channel must be loaded before its
     * messages can be read ("Chat not found" otherwise).
     */
    suspend fun ensureChat(chatId: Long) {
        if (chatId in loadedChats) return
        var ok = runCatching { td.send(TdApi.GetChat(chatId)) }.isSuccess
        if (!ok) {
            // Channel chat ids are -100<supergroup id>.
            val supergroupId = -(chatId + 1_000_000_000_000L)
            if (supergroupId > 0) ok = runCatching { td.send(TdApi.CreateSupergroupChat(supergroupId, true)) }.isSuccess
        }
        if (!ok) {
            runCatching { td.send(TdApi.LoadChats(TdApi.ChatListMain(), 500)) }
            ok = runCatching { td.send(TdApi.GetChat(chatId)) }.isSuccess
        }
        if (ok) loadedChats += chatId else AppLog.warn("Couldn't load the library channel")
    }

    /** One page of document messages, newest first, from [fromMessageId] (0 = the newest). FLOOD_WAIT is waited out. */
    suspend fun documents(chatId: Long, fromMessageId: Long, limit: Int = 100): TdApi.FoundChatMessages = retryingFloodWait {
        td.send(TdApi.SearchChatMessages(chatId, null, "", null, fromMessageId, 0, limit, TdApi.SearchMessagesFilterDocument()))
    }

    /** TDLib's file for a persistent remote id (no message lookup, so no extra round trip). */
    suspend fun file(remoteId: String): TdApi.File = retryingFloodWait { td.send(TdApi.GetRemoteFile(remoteId, null)) }

    /** Downloads the whole file and returns its local copy. */
    suspend fun download(remoteId: String, priority: Int = 16): File {
        val f = file(remoteId)
        if (f.local.isDownloadingCompleted && File(f.local.path).isFile) return File(f.local.path)
        return gate(f.id).withLock {
            val done = retryingFloodWait { td.send(TdApi.DownloadFile(f.id, priority, 0, 0, true)) }
            if (!done.local.isDownloadingCompleted) throw TelegramException(0, "Download incomplete")
            File(done.local.path)
        }
    }

    /**
     * Exactly [count] bytes at [offset] of the stored file, downloading only that range. Short reads come back short
     * only at the end of the file.
     */
    suspend fun read(remoteId: String, offset: Long, count: Long): ByteArray {
        val f = file(remoteId)
        val wanted = minOf(count, maxOf(0, f.size - offset))
        if (wanted <= 0) return ByteArray(0)
        return gate(f.id).withLock {
            var last: Throwable? = null
            repeat(5) {
                try {
                    retryingFloodWait { td.send(TdApi.DownloadFile(f.id, 32, offset, wanted, true)) }
                    val data = readPart(f.id, offset, wanted)
                    if (data.size.toLong() == wanted) return@withLock data
                    last = TelegramException(0, "Short read")
                } catch (e: TelegramException) {
                    last = e
                    // Another download of this file replaced ours: it fetches the same bytes, so try again shortly.
                    if (!e.message.contains("Canceled by another")) throw e
                }
                delay(200)
            }
            throw last ?: TelegramException(0, "Read failed")
        }
    }

    /** Removes TDLib's downloaded copy (the file stays in Telegram). */
    suspend fun deleteLocalCopy(remoteId: String) {
        runCatching { td.send(TdApi.DeleteFile(file(remoteId).id)) }
    }

    /**
     * `readFilePart`, falling back to the file on disk: TDLib refuses to read a file outside its cache ("File is not
     * inside the cache"), which happens to files this device uploaded (iOS `readPart`).
     */
    private suspend fun readPart(fileId: Int, offset: Long, count: Long): ByteArray = try {
        td.send(TdApi.ReadFilePart(fileId, offset, count)).data
    } catch (e: TelegramException) {
        val f = td.send(TdApi.GetFile(fileId))
        val path = f.local.path
        if (!f.local.isDownloadingCompleted || path.isEmpty()) throw e
        RandomAccessFile(path, "r").use { raf ->
            raf.seek(offset)
            val out = ByteArray(count.toInt())
            raf.readFully(out)
            out
        }
    }

    private fun gate(fileId: Int) = gates.getOrPut(fileId) { Mutex() }

    private suspend fun <T> retryingFloodWait(block: suspend () -> T): T {
        while (true) {
            try {
                return block()
            } catch (e: TelegramException) {
                // Honour FLOOD_WAIT exactly (AGENTS.md rule 3).
                val wait = TelegramErrors.floodWaitSeconds(e.message) ?: throw e
                AppLog.warn("Telegram asked to wait $wait s")
                delay(wait * 1000L)
            }
        }
    }
}
