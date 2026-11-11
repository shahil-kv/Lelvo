package app.lelvo.telegram

import app.lelvo.core.support.AppLog
import app.lelvo.core.session.TelegramErrors
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
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

    /** Where the continuous streaming download of each file last started, and when (TDLib keeps one per file). */
    private val windows = ConcurrentHashMap<Int, Long>()
    private val windowMoved = ConcurrentHashMap<Int, Long>()

    /**
     * A streaming read for the video player (iOS `streamRead`): one continuous TDLib download runs ahead of the
     * playhead, like Telegram's own players, instead of one request per slice, which can't keep up with 4K. Reads
     * up to [ahead] past the running download wait for it rather than restarting it (a restart costs ~0.4 s to the
     * first bytes, and after a seek the player asks for several nearby ranges at once).
     *
     * [smallReads]: a small read outside the download (an original's index at the end of the file) fetches just its
     * range. Off for fast versions, whose index comes first: there, separate small downloads kept cancelling the main
     * one (TDLib runs one download per file), as Unigram's TDLib player found.
     *
     * Gives up after 30 s without the data, so playback reports an error instead of hanging.
     */
    suspend fun streamRead(remoteId: String, offset: Long, count: Long, ahead: Long = 2L shl 20, smallReads: Boolean = true): ByteArray {
        val f = file(remoteId)
        val wanted = minOf(count, maxOf(0, f.size - offset))
        if (wanted <= 0) return ByteArray(0)
        val id = f.id
        val started = System.currentTimeMillis()
        val done = withTimeoutOrNull(30_000) {
            var mine = false
            var lastIssue = 0L
            var moves = 0
            var small = false
            while (true) {
                val have = runCatching { td.send(TdApi.GetFileDownloadedPrefixSize(id, offset)).size }.getOrDefault(0L)
                if (have >= wanted) break
                val now = td.send(TdApi.GetFile(id))
                if (now.local.isDownloadingCompleted) break
                // Where TDLib is really downloading, not where we last asked: anything else that downloads this file
                // moves it, and a stale note left reads waiting for data that never came.
                val begin = now.local.downloadOffset
                val end = begin + now.local.downloadedPrefixSize
                val covered = now.local.isDownloadingActive && begin <= offset && offset <= end + ahead
                if (!covered && smallReads && wanted <= SMALL_READ) {
                    gate(id).withLock {
                        windows.remove(id)
                        retryingFloodWait { td.send(TdApi.DownloadFile(id, 32, offset, wanted, true)) }
                    }
                    small = true
                    break
                }
                val t = System.currentTimeMillis()
                // Another read just moved the download: give it a moment rather than moving it straight back.
                val movedRecently = windowMoved[id]?.let { t - it < 1_000 } == true
                if (!covered && !smallReads && movedRecently && !mine && t - started < 1_500) {
                    awaitFileUpdate(id)
                    continue
                }
                val movedByOthers = mine && windows[id] == null
                if (!covered && (lastIssue == 0L || movedByOthers || t - lastIssue > 2_000)) {
                    gate(id).withLock { retryingFloodWait { td.send(TdApi.DownloadFile(id, 32, offset, 0, false)) } }
                    windows[id] = offset
                    windowMoved[id] = t
                    mine = true
                    lastIssue = t
                    moves++
                }
                // TDLib reports each downloaded piece with updateFile; the timeout keeps the steps above running.
                awaitFileUpdate(id)
            }
            val waited = System.currentTimeMillis() - started
            if (waited > 1_000) {
                val how = if (small) ", fetched on its own" else if (moves > 0) ", download restarted ${moves}×" else ""
                AppLog.warn("Playback waited ${"%.1f".format(waited / 1000.0)} s for $wanted bytes at $offset$how")
            }
            true
        }
        if (done == null) {
            AppLog.warn("Stream gave up after 30 s: $wanted bytes at $offset")
            throw TelegramException(0, "Telegram didn't deliver this video's data for 30 s")
        }
        return readPart(id, offset, wanted)
    }

    private suspend fun awaitFileUpdate(id: Int) {
        withTimeoutOrNull(250) { td.updates.first { it is TdApi.UpdateFile && it.file.id == id } }
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

    private companion object { const val SMALL_READ = 512L shl 10 }

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
