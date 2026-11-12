package app.lelvo.telegram

import app.lelvo.core.backup.UploadStall
import app.lelvo.core.format.PartLayout
import app.lelvo.core.support.AppLog
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.filterIsInstance
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.drinkless.tdlib.TdApi
import java.io.File

/** The send stopped moving for [UploadStall.DEFAULT_TIMEOUT_MS] and was cancelled; try again. */
class UploadStalledException(val sent: Long, val total: Long) :
    Exception("The upload stopped moving at ${sent shr 20} of ${total shr 20} MB. It will be tried again.")

/**
 * Writing documents to the library channel (iOS `TDService.sendDocument` and `deleteMessages`). Callers check
 * `LibraryService.requireWritable` first; nothing here knows which channel is allowed.
 */
class TdUploads(private val td: TdClient, private val files: TdFiles) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val _speedLimited = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    /** Telegram slowed uploads for an account without Premium; the Backup tab says so instead of looking stuck. */
    val speedLimited: SharedFlow<Unit> = _speedLimited
    @Volatile private var lastSpeedLog = 0L

    init {
        scope.launch {
            td.updates.filterIsInstance<TdApi.UpdateSpeedLimitNotification>().collect {
                if (!it.isUpload) return@collect
                _speedLimited.tryEmit(Unit)
                val now = System.currentTimeMillis()
                if (now - lastSpeedLog > 300_000) {
                    lastSpeedLog = now
                    AppLog.info("Telegram limits upload speed for this account (no Premium)")
                }
            }
        }
    }

    /** Per-file upload limit: 4000 MiB with Premium, otherwise 2000 MiB. */
    suspend fun uploadLimit(): Long {
        val me = runCatching { td.send(TdApi.GetMe()) }.getOrNull()
        return if (me?.isPremium == true) PartLayout.PREMIUM_LIMIT else PartLayout.STANDARD_LIMIT
    }

    /**
     * Sends a local file as a document and returns only once Telegram has stored it. [progress] reports (sent, total)
     * bytes. Cancelling the coroutine deletes the pending message, so a half-sent part never stays in the channel.
     */
    suspend fun sendDocument(
        chatId: Long, file: File, caption: String, thumbnail: Triple<File, Int, Int>? = null,
        progress: (Long, Long) -> Unit = { _, _ -> },
    ): TdApi.Message = withContext(Dispatchers.IO) {
        files.ensureChat(chatId)
        val content = TdApi.InputMessageDocument(
            TdApi.InputDocument(
                TdApi.InputFileLocal(file.path),
                thumbnail?.let { TdApi.InputThumbnail(TdApi.InputFileLocal(it.first.path), it.second, it.third) },
                true,
            ),
            TdApi.FormattedText(caption, emptyArray()),
        )
        val options = TdApi.MessageSendOptions(null, true, true, false, false, 0, false, null, 0, 0, false)
        val pending = td.send(TdApi.SendMessage(chatId, null, null, options, null, content))
        val fileId = (pending.content as? TdApi.MessageDocument)?.document?.document?.id
        try {
            coroutineScope {
                val stall = UploadStall(System.currentTimeMillis())
                val stallLock = Any()
                val watcher = fileId?.let { id ->
                    launch {
                        td.updates.filterIsInstance<TdApi.UpdateFile>().collect { u ->
                            if (u.file.id != id) return@collect
                            val sent = u.file.remote.uploadedSize
                            val total = u.file.expectedSize.takeIf { it > 0 } ?: u.file.size
                            synchronized(stallLock) { stall.record(sent, System.currentTimeMillis()) }
                            progress(sent, total)
                        }
                    }
                }
                val watchdog = launch {
                    while (isActive) {
                        delay(10_000)
                        val stalled = synchronized(stallLock) { stall.check(System.currentTimeMillis()) }
                        if (!stalled) continue
                        val sent = synchronized(stallLock) { stall.sent }
                        // Retry only once the stuck send is gone: if it could still finish, its part would sit in the
                        // channel unrecorded next to the retry's, and a scan keeps the lowest message id of each part.
                        val deleted = runCatching { td.send(TdApi.DeleteMessages(chatId, longArrayOf(pending.id), true)) }
                        if (deleted.isFailure) {
                            AppLog.warn("Upload stopped moving at ${sent shr 20} MB and cancelling it failed; waiting for it")
                            synchronized(stallLock) { stall.restart(System.currentTimeMillis()) }
                            continue
                        }
                        AppLog.warn("Upload stopped moving at ${sent shr 20} MB for ${UploadStall.DEFAULT_TIMEOUT_MS / 1000} s; trying again")
                        td.finishSend(pending.id, Result.failure(UploadStalledException(sent, file.length())))
                        return@launch
                    }
                }
                try {
                    td.awaitSent(pending.id)
                } finally {
                    watcher?.cancel()
                    watchdog.cancel()
                }
            }
        } catch (e: CancellationException) {
            withContext(NonCancellable) { runCatching { td.send(TdApi.DeleteMessages(chatId, longArrayOf(pending.id), true)) } }
            throw e
        }
    }

    /**
     * Deletes messages from the channel for everyone. TDLib quietly skips messages it doesn't have in memory and still
     * answers OK (iOS lost deletes that way), so they are loaded first.
     */
    suspend fun deleteMessages(chatId: Long, ids: List<Long>) = withContext(Dispatchers.IO) {
        if (ids.isEmpty()) return@withContext
        files.ensureChat(chatId)
        ids.chunked(100).forEach { batch ->
            val array = batch.toLongArray()
            td.send(TdApi.GetMessages(chatId, array))
            td.send(TdApi.DeleteMessages(chatId, array, true))
        }
    }

    /**
     * The stored size of a document message, or null when the message is gone or isn't a document. Other errors
     * (network) throw, so a check that couldn't run never passes as "gone" or "there".
     */
    suspend fun documentSize(chatId: Long, messageId: Long): Long? = withContext(Dispatchers.IO) {
        files.ensureChat(chatId)
        val m = try {
            td.send(TdApi.GetMessage(chatId, messageId))
        } catch (e: TelegramException) {
            if (e.code == 404 || e.code == 400) return@withContext null
            throw e
        }
        (m.content as? TdApi.MessageDocument)?.document?.document?.size
    }

    /** Forgets TDLib's local copy of an uploaded file, so later reads go to Telegram instead of a deleted temp file. */
    suspend fun forgetLocalCopy(fileId: Int) {
        runCatching { td.send(TdApi.DeleteFile(fileId)) }
    }
}
