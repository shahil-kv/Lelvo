package app.lelvo.data.backup

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.StatFs
import app.lelvo.core.backup.BackupCounts
import app.lelvo.core.backup.Dedupe
import app.lelvo.core.backup.JobEvent
import app.lelvo.core.backup.PhotoChangeScan
import app.lelvo.core.backup.ScreenCopyPolicy
import app.lelvo.core.backup.TelegramErrorClassifier
import app.lelvo.core.backup.TelegramErrorKind
import app.lelvo.core.backup.TransferRate
import app.lelvo.core.backup.UploadNames
import app.lelvo.core.backup.UploadOrder
import app.lelvo.core.backup.UploadSlots
import app.lelvo.core.backup.reduced
import app.lelvo.core.crypto.CryptoException
import app.lelvo.core.format.CaptionMeta
import app.lelvo.core.format.IndexSnapshot
import app.lelvo.core.index.LibraryIndexer
import app.lelvo.core.crypto.FileCrypto
import app.lelvo.core.format.Kind
import app.lelvo.core.format.Role
import app.lelvo.core.index.ItemKind
import app.lelvo.core.index.ItemStatus
import app.lelvo.core.index.LibraryItem
import app.lelvo.core.session.TelegramErrors
import app.lelvo.core.video.StreamingCopyPolicy
import app.lelvo.core.support.AppLog
import app.lelvo.data.LibraryException
import app.lelvo.data.LibraryScanner
import app.lelvo.data.LibraryService
import app.lelvo.data.Prefs
import app.lelvo.data.index.LibraryStore
import app.lelvo.data.media.PhotoAccess
import app.lelvo.data.media.PhotoLinker
import app.lelvo.telegram.TelegramException
import app.lelvo.telegram.TdUploads
import app.lelvo.telegram.UploadStalledException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.util.TimeZone
import java.util.UUID
import kotlin.coroutines.coroutineContext

/** Live state for the Backup tab (iOS `BackupActivity`). */
data class BackupActivity(
    val isRunning: Boolean = false,
    val done: Int = 0,
    val total: Int = 0,
    /** Per upload lane: the file being uploaded and its byte progress. */
    val lanes: Map<String, Lane> = emptyMap(),
    /** Per lane: about how many seconds its file still needs at the recent speed. */
    val secondsLeft: Map<String, Int> = emptyMap(),
    val uploaded: Int = 0,
    val failed: Int = 0,
    val message: String? = null,
    /** Temporary notice (Telegram's pause, its speed limit); cleared when it ends. */
    val notice: String? = null,
    val lastSummary: BackupEngine.Summary? = null,
    /** Bumped each time an item is confirmed in full, with its phone id, for the Backup tab's animation. */
    val landed: Pair<String, Int>? = null,
) {
    data class Lane(val name: String, val sent: Long, val total: Long)

    val remaining: Int get() = maxOf(0, total - done)
}

/**
 * Runs the persistent upload queue: queued → uploading → backedUp | failed (iOS `BackupEngine`). An item counts as
 * backed up only after Telegram confirmed every part and each stored size matched. At most two uploads at once, 1.5 s
 * apart, and every FLOOD_WAIT waited out exactly.
 */
class BackupEngine(
    context: Context,
    private val store: LibraryStore,
    private val library: LibraryService,
    private val scanner: LibraryScanner,
    private val uploads: TdUploads,
    private val photos: PhotoAccess,
    private val linker: PhotoLinker,
    private val prefs: Prefs,
    private val reader: app.lelvo.data.media.MediaReader,
) {
    private val app = context.applicationContext
    val phone = PhoneFiles(app)
    private val staging = File(app.cacheDir, "backup")
    private val uploader = CloudUploader(uploads, library, staging).also { it.beforeSend = { waitForFloodPause() } }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    data class Summary(val uploaded: Int = 0, val alreadyBackedUp: Int = 0, val failed: Int = 0, val remaining: Int = 0, val error: String? = null) {
        val text: String
            get() = error ?: buildList {
                add("Backed up $uploaded item${if (uploaded == 1) "" else "s"}")
                if (alreadyBackedUp > 0) add("$alreadyBackedUp already in the cloud")
                if (failed > 0) add("$failed failed")
                if (remaining > 0) add("$remaining still waiting")
            }.joinToString(", ") + "."
    }

    /** Same sentences as iOS `StopReason`. */
    enum class StopReason(val text: String) {
        NotConfigured("Lelvo isn't set up yet. Open the app to sign in to Telegram."),
        NoPhotoAccess("Lelvo has no access to your photos."),
        WaitingForWiFi("Waiting for Wi-Fi (Wi-Fi only is on)."),
        WaitingForPower("Waiting for the charger (Charging only is on)."),
        Offline("No internet connection."),
        AlreadyRunning("A backup is already running."),
    }

    private enum class Outcome { Uploaded, Duplicate, Failed, Skipped, RetryLater }

    private val _activity = MutableStateFlow(BackupActivity())
    val activity: StateFlow<BackupActivity> = _activity
    private val rates = HashMap<String, Pair<String, TransferRate>>()

    private val gate = Any()
    private val slots = UploadSlots(MAX_CONCURRENT_UPLOADS)
    private var nextUploadStart = 0L
    private var pausedUntil = 0L
    private var running = false
    private var waitingLanes = 0
    @Volatile private var pauseRequested = false
    private var runJob: Job? = null

    init {
        scope.launch {
            uploads.speedLimited.collect {
                val a = _activity.value
                if (a.isRunning && a.notice == null) {
                    _activity.update { it.copy(notice = "Telegram limits upload speed for accounts without Premium. The backup continues, just slower.") }
                }
            }
        }
    }

    val isRunning: Boolean get() = synchronized(gate) { running }

    /**
     * Stops the running backup at once (uploads in flight go back to the queue; their half-sent message is deleted) and
     * keeps it paused for automatic runs until the user taps Back up now.
     */
    fun pause() {
        prefs.backupPaused = true
        pauseRequested = true
        synchronized(gate) { runJob }?.cancel()
        AppLog.info("Backup paused by the user")
    }

    /** Why the queue can't run right now; null when it can. */
    fun blocker(): StopReason? {
        if (!library.isConfigured || !library.isUnlocked) return StopReason.NotConfigured
        val access = photos.status()
        if (access != PhotoAccess.Status.Full && access != PhotoAccess.Status.Partial) return StopReason.NoPhotoAccess
        val net = network()
        if (net == null) return StopReason.Offline
        if (prefs.wifiOnly && !net) return StopReason.WaitingForWiFi
        if (prefs.chargingOnly && !charging()) return StopReason.WaitingForPower
        return null
    }

    /** Null offline, else true on an unmetered network (Wi-Fi, Ethernet). Metered and hotspots count as mobile data. */
    private fun network(): Boolean? = runCatching {
        val cm = app.getSystemService(ConnectivityManager::class.java)
        val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return null
        if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) return null
        caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
    }.getOrDefault(true)

    private fun charging() = app.getSystemService(BatteryManager::class.java)?.isCharging == true

    // MARK: Queue

    /** The phone files the backup selection covers (iOS `backupCandidates`). */
    private fun candidates(among: List<PhoneFile> = phone.all()): List<PhoneFile> {
        val from = prefs.dateFrom
        val albums = prefs.albumIds
        return among.filter { f ->
            when (prefs.mediaFilter) {
                Prefs.MediaFilter.Photos -> !f.isVideo
                Prefs.MediaFilter.Videos -> f.isVideo
                Prefs.MediaFilter.All -> true
            } && (prefs.backupVideos || !f.isVideo) &&
                (prefs.includeScreenshots || !isScreenshot(f)) &&
                (from == null || (f.createdAt ?: Long.MAX_VALUE) >= from) &&
                when (prefs.albumMode) {
                    Prefs.AlbumMode.All -> true
                    Prefs.AlbumMode.Include -> f.bucketId in albums
                    Prefs.AlbumMode.Exclude -> f.bucketId !in albums
                }
        }
    }

    private fun isScreenshot(f: PhoneFile) =
        f.bucketName.equals("Screenshots", ignoreCase = true) || f.relativePath?.contains("Screenshots", ignoreCase = true) == true

    /** Adds phone photos the selection covers and the index doesn't know as queued items. */
    suspend fun enqueueNew(): Int {
        val known = store.knownLocalIds() + store.offBackupLocalIds()
        val fresh = candidates().filter { it.localId !in known }.map(::makeItem)
        store.upsert(fresh)
        return fresh.size
    }

    /** "Back up" on chosen photos: queued whatever the selection says, failed ones retried. */
    suspend fun enqueue(localIds: List<String>): Int {
        val files = phone.files(localIds)
        val out = ArrayList<LibraryItem>()
        for (id in localIds) {
            store.allowBackup(id)
            val existing = store.itemForPhone(id)
            if (existing != null) {
                // Recovering from Recently Deleted sends a note: Phase L.
                if (existing.status == ItemStatus.BackedUp || existing.status == ItemStatus.Trashed) continue
                out += (if (existing.status == ItemStatus.Failed) existing.reduced(JobEvent.Retry) else existing).copy(chosen = true)
            } else {
                files[id]?.let { out += makeItem(it).copy(chosen = true) }
            }
        }
        store.upsert(out)
        return out.size
    }

    /** Moves every failed item that a retry can help back to the queue (the Retry button). */
    suspend fun retryFailed(): Int {
        val failed = store.items(ItemStatus.Failed).filter { !it.isStrandedInCloud && it.localId != null }
        store.upsert(failed.map { it.reduced(JobEvent.Retry).copy(chosen = true) })
        return failed.size
    }

    /** What the Backup tab shows as left, failed and retryable. */
    suspend fun counts(): BackupCounts = withContext(Dispatchers.IO) {
        val queued = store.items(ItemStatus.Queued) + store.items(ItemStatus.Uploading)
        BackupCounts.compute(
            queued = queued, failed = store.items(ItemStatus.Failed), candidates = candidates().map { it.localId },
            known = store.knownLocalIds(), offBackup = store.offBackupLocalIds(), autoBackup = prefs.autoBackup,
        )
    }

    /** Queued items whose photo was deleted from the phone before it was uploaded go (iOS `dropDeletedQueuedItems`). */
    private suspend fun dropDeletedQueuedItems(): Int {
        store.items(ItemStatus.Queued).filter { it.isStrandedInCloud }.takeIf { it.isNotEmpty() }?.let { stuck ->
            store.upsert(stuck.map { it.photoLeftDevice() })
        }
        val queued = store.items(ItemStatus.Queued)
        val ids = queued.mapNotNull { it.localId }
        if (ids.isEmpty()) return 0
        val present = phone.files(ids).keys
        val gone = PhotoChangeScan.queuedButDeleted(queued, present, libraryIsEmpty = phone.all().isEmpty())
        val dropped = gone.count { store.deleteIfQueued(it.id) }
        if (dropped > 0) AppLog.info("Dropped $dropped queued items deleted from the phone")
        return dropped
    }

    private fun makeItem(f: PhoneFile) = LibraryItem(
        id = UUID.randomUUID().toString().lowercase(), localId = f.localId, sha256 = "", filename = f.filename, kind = f.kind,
        createdAt = f.createdAt, width = f.width, height = f.height, duration = f.duration, fileSize = 0,
        status = ItemStatus.Queued, favorite = f.isFavorite, encrypted = true,
    )

    private fun runnable(now: Long, onlyChosen: Boolean, items: List<LibraryItem>) =
        UploadOrder.sorted(items.filter { it.localId != null && (it.notBefore?.let { nb -> nb <= now } ?: true) && (!onlyChosen || it.chosen) })

    // MARK: Run

    /**
     * Processes the queue with up to two uploads at once until it's empty or the run is paused. [includeNew]: also
     * queue every photo not yet in the cloud ("Back up now"); otherwise only queued items (chosen photos, retries) go,
     * unless automatic backup is on.
     */
    suspend fun run(userStarted: Boolean, includeNew: Boolean): Summary = withContext(Dispatchers.IO) {
        if (userStarted) prefs.backupPaused = false
        else if (prefs.backupPaused) return@withContext Summary(error = "Backup is paused. Open Lelvo and tap Back up now to resume.")
        blocker()?.let { reason ->
            // A tap must say why nothing happens, or the button looks broken.
            return@withContext finish(Summary(error = reason.text), started = false, announce = userStarted)
        }
        val chatId = library.chatId ?: return@withContext finish(Summary(error = StopReason.NotConfigured.text), started = false, announce = userStarted)
        synchronized(gate) {
            if (running) return@withContext Summary(error = StopReason.AlreadyRunning.text)
            running = true
            runJob = coroutineContext[Job]
        }
        pauseRequested = false
        try {
            _activity.update { it.copy(isRunning = true, message = "Connecting to Telegram…", lanes = emptyMap(), notice = null) }
            // Anything sent before an interruption is found first, so it isn't uploaded twice.
            runCatching { scanner.scan(full = false) }.onFailure { if (it is CancellationException) throw it }
            runCatching { linker.relink() }
            dropDeletedQueuedItems()
            if (includeNew || prefs.autoBackup) {
                val t = System.currentTimeMillis()
                val queued = enqueueNew()
                AppLog.info("Looked for new photos: $queued queued, in ${System.currentTimeMillis() - t} ms")
            }
            // Left "uploading" by a killed process: back to the queue.
            store.items(ItemStatus.Uploading).takeIf { it.isNotEmpty() }?.let { stale -> store.upsert(stale.map { it.reduced(JobEvent.Interrupted) }) }

            val onlyChosen = !includeNew && !prefs.autoBackup
            val queue = ArrayDeque(runnable(System.currentTimeMillis(), onlyChosen, store.items(ItemStatus.Queued)))
            val total = queue.size
            _activity.update {
                it.copy(done = 0, total = total, uploaded = 0, failed = 0, lanes = emptyMap(),
                    message = if (total == 0) "Everything is backed up." else "Backing up $total items…")
            }
            AppLog.info("Backup run: $total items queued")
            val counter = Counter()
            val queueLock = Mutex()
            val requeues = HashMap<String, Int>()
            coroutineScope {
                repeat(MAX_CONCURRENT_UPLOADS) { lane ->
                    launch {
                        while (isActive) {
                            val item = queueLock.withLock { queue.removeFirstOrNull() } ?: break
                            // A blip (Wi-Fi roaming) shouldn't end the run; wait it out, stop only if it lasts.
                            waitForConditions()?.let { reason ->
                                _activity.update { it.copy(message = reason.text) }
                                if (queueLock.withLock { queue.isNotEmpty().also { queue.clear() } }) AppLog.info("Backup stopped: ${reason.text} (for over 2 minutes)")
                                return@launch
                            }
                            waitForFloodPause()
                            acquireLaneSlot()
                            val outcome = try {
                                paceUploadStart()
                                process(item, lane)
                            } finally {
                                synchronized(gate) { slots.release() }
                            }
                            if (outcome == Outcome.RetryLater) {
                                // Slowed down or a network error: try again later in this run, at most 5 times.
                                val n = requeues.getOrDefault(item.id, 0)
                                if (n < 5) { requeues[item.id] = n + 1; queueLock.withLock { queue.addLast(item) }; continue }
                            }
                            val (done, snap) = counter.record(outcome)
                            _activity.update { a ->
                                a.copy(done = done, uploaded = snap.first + snap.second, failed = snap.third,
                                    landed = if (outcome == Outcome.Uploaded) (item.localId ?: "") to done else a.landed)
                            }
                        }
                    }
                }
            }
            makeEarlierScreenCopies()
            waitForFloodPause()
            writeSnapshotIfDue()
            val snap = counter.snapshot()
            val left = runnable(Long.MAX_VALUE, onlyChosen, store.items(ItemStatus.Queued)).size
            val summary = Summary(uploaded = snap.first, alreadyBackedUp = snap.second, failed = snap.third, remaining = left)
            if (summary.uploaded > 0) prefs.lastBackupAt = System.currentTimeMillis()
            AppLog.info("Backup run finished: ${summary.text}")
            finish(summary, started = true, announce = userStarted)
        } catch (e: CancellationException) {
            val paused = pauseRequested
            val s = Summary(error = if (paused) "Paused. Tap Back up now to continue where it stopped." else null)
            AppLog.info("Backup stopped: ${if (paused) "paused" else "ended"}")
            finish(s, started = true, announce = userStarted)
            throw e
        } finally {
            synchronized(gate) { running = false; runJob = null }
        }
    }

    /** [announce]: the user started the run, so the Backup tab says how it went (iOS `announce`); automatic runs stay quiet. */
    private fun finish(summary: Summary, started: Boolean, announce: Boolean): Summary {
        _activity.update {
            it.copy(isRunning = false, lastSummary = if (announce) summary else it.lastSummary, message = summary.text, lanes = emptyMap(), secondsLeft = emptyMap(),
                notice = null, total = if (started) it.total else 0)
        }
        rates.clear()
        return summary
    }

    private suspend fun acquireLaneSlot() {
        while (!synchronized(gate) { slots.acquireForLane() }) delay(200)
    }

    /** At least [UPLOAD_SPACING_MS] between upload starts, across both lanes, so Telegram rarely has to say "slow down". */
    private suspend fun paceUploadStart() {
        val wait = synchronized(gate) {
            val now = System.currentTimeMillis()
            val slot = maxOf(now, nextUploadStart)
            nextUploadStart = slot + UPLOAD_SPACING_MS
            slot - now
        }
        if (wait > 0) delay(wait)
    }

    /** Holds a send until Telegram's FLOOD_WAIT is over; both lanes wait for the same pause. */
    private suspend fun waitForFloodPause() {
        var paused = false
        while (true) {
            val wait = synchronized(gate) { pausedUntil } - System.currentTimeMillis()
            if (wait <= 0) break
            paused = true
            _activity.update { it.copy(notice = "Telegram asked to slow down: resuming in ${(wait + 999) / 1000} s.") }
            delay(minOf(wait, 1000))
        }
        if (paused) _activity.update { it.copy(notice = null) }
    }

    /**
     * Runs a note send (Recently Deleted, favorites and albums) in one of the two upload slots, after the same pacing
     * and FLOOD_WAIT pause as uploads (iOS `withNoteSlot`). A waiting note goes before the lanes' next upload. A
     * FLOOD_WAIT from the send holds every lane and the note is tried again once it's over.
     */
    suspend fun withNoteSlot(send: suspend () -> Unit) {
        while (true) {
            try {
                while (!synchronized(gate) { slots.acquireForNote() }) delay(200)
            } catch (e: CancellationException) {
                synchronized(gate) { slots.stopWaitingForNote() }
                throw e
            }
            try {
                val wait = synchronized(gate) { pausedUntil } - System.currentTimeMillis()
                if (wait > 0) { delay(wait); continue }
                paceUploadStart()
                try {
                    send()
                    return
                } catch (e: TelegramException) {
                    val flood = TelegramErrorClassifier.classify(e.code, e.message) as? TelegramErrorKind.FloodWait ?: throw e
                    holdFor(flood.seconds)
                }
            } finally {
                synchronized(gate) { slots.release() }
            }
        }
    }

    private fun holdFor(seconds: Int) = synchronized(gate) { pausedUntil = maxOf(pausedUntil, System.currentTimeMillis() + seconds * 1000L) }

    /** Null when the backup may go on; waits up to [patienceMs] for a condition to clear and says what it waits for. */
    private suspend fun waitForConditions(patienceMs: Long = 120_000): StopReason? {
        var reason = blocker() ?: return null
        val first = synchronized(gate) { waitingLanes++; waitingLanes == 1 }
        try {
            if (first) AppLog.info("Backup waiting: ${reason.text}")
            val until = System.currentTimeMillis() + patienceMs
            while (System.currentTimeMillis() < until) {
                _activity.update { it.copy(message = reason.text) }
                delay(2_000)
                val still = blocker()
                if (still == null) {
                    if (first) AppLog.info("Backup continuing")
                    _activity.update { it.copy(message = null) }
                    return null
                }
                reason = still
            }
            return reason
        } finally {
            synchronized(gate) { waitingLanes-- }
        }
    }

    private fun showLane(key: String, lane: BackupActivity.Lane?) {
        val now = System.currentTimeMillis()
        _activity.update { a ->
            val lanes = if (lane == null) a.lanes - key else a.lanes + (key to lane)
            val left = HashMap<String, Int>()
            synchronized(rates) {
                for ((k, l) in lanes) {
                    if (l.total <= 0) continue
                    val entry = rates[k]?.takeIf { it.first == l.name } ?: (l.name to TransferRate())
                    entry.second.record(l.sent, now)
                    rates[k] = entry
                    entry.second.secondsLeft(l.total)?.let { left[k] = it }
                }
                rates.keys.retainAll(lanes.keys)
            }
            a.copy(lanes = lanes, secondsLeft = left)
        }
    }

    // MARK: One item

    private suspend fun process(queued: LibraryItem, lane: Int): Outcome {
        var item = store.item(queued.id) ?: return Outcome.Skipped
        if (item.status != ItemStatus.Queued && item.status != ItemStatus.Uploading) return Outcome.Skipped
        val localId = item.localId ?: return Outcome.Skipped
        val file = phone.file(localId)
        if (file == null) {
            // Without access to photos every photo looks deleted: leave it until access comes back.
            if (blocker() == StopReason.NoPhotoAccess) return Outcome.Skipped
            if (item.hasCloudParts) {
                // Part of it is in the channel: the item stays (as failed, so it can be deleted) rather than vanish.
                item = item.photoLeftDevice()
                store.upsert(listOf(item))
                return if (item.status == ItemStatus.Failed) Outcome.Failed else Outcome.Skipped
            }
            store.delete(item.id)
            return Outcome.Skipped
        }
        item = item.reduced(JobEvent.Start)
        store.upsert(listOf(item))
        val laneKey = "$lane"
        showLane(laneKey, BackupActivity.Lane(item.filename, 0, 0))
        val thumbFile = File(staging, "${item.id}-thumb.jpg")
        try {
            // Tried before and unchanged since: the duplicate check can use the stored hash without reading the file.
            if (!item.hasCloudParts && item.sha256.isNotEmpty() && item.assetModifiedAt != null && item.assetModifiedAt == file.modifiedAt) {
                store.items(item.sha256).firstOrNull { it.id != item.id && it.status == ItemStatus.BackedUp }?.let { twin ->
                    link(item, localId, twin)
                    AppLog.info("${item.filename} is already backed up (stored hash, not read again)")
                    return Outcome.Duplicate
                }
            }
            val free = runCatching { StatFs(staging.apply { mkdirs() }.path).availableBytes }.getOrDefault(Long.MAX_VALUE)
            val needed = UploadNames.spaceNeeded(listOf(file.size), uploads.uploadLimit()) + UploadNames.SPACE_MARGIN
            if (free < needed) {
                AppLog.info("Not enough space to back up ${item.filename}: needs ${needed shr 20} MB, ${free shr 20} MB free")
                throw NotEnoughSpaceException(needed - free)
            }
            // A retry of an unchanged file reuses its hash: hashing a 3 GB video again took minutes of battery on iOS.
            val reuse = Dedupe.canReuseHashes(item, file.modifiedAt, file.size, null)
            if (reuse) AppLog.info("Reusing the stored hash of ${item.filename} (unchanged since the last try)")
            val (hash, size) = if (reuse) item.sha256 to item.fileSize else phone.hash(file)
            if (!item.hasCloudParts) {
                store.items(hash).firstOrNull { it.id != item.id && it.status == ItemStatus.BackedUp }?.let { twin ->
                    link(item, localId, twin)
                    return Outcome.Duplicate
                }
                // Another copy of a photo deleted from the backup: stays on the phone unless the user asks.
                if (!item.chosen && (store.isOffBackup(hash, null) || store.items(hash).any { it.id != item.id && it.status == ItemStatus.Trashed })) {
                    store.delete(item.id)
                    store.keepOffBackup(localId)
                    AppLog.info("${item.filename} was deleted from your backup, so it wasn't uploaded again")
                    return Outcome.Skipped
                }
            }
            val place = phone.location(file)
            item = item.copy(
                sha256 = hash, filename = file.filename, kind = file.kind, fileSize = size, width = file.width, height = file.height,
                duration = file.duration, createdAt = file.createdAt ?: item.createdAt, favorite = file.isFavorite,
                latitude = place?.first, longitude = place?.second, encrypted = true, mimeType = file.mimeType,
                codec = if (file.isVideo) phone.videoCodec(file) else null,
                tzOffsetMinutes = TimeZone.getDefault().getOffset(file.createdAt ?: System.currentTimeMillis()) / 60_000,
                assetModifiedAt = file.modifiedAt, roleHashes = item.roleHashes + ("o" to hash),
            )
            store.upsert(listOf(item))

            // E2E: the thumbnail is its own encrypted message (role `t`); Telegram never sees a picture.
            val thumb = phone.thumbnail(file) ?: throw IOException("Couldn't make a thumbnail of this photo")
            thumbFile.parentFile?.mkdirs()
            thumbFile.writeBytes(thumb.first)
            val thumbHash = PhoneFiles.hex(java.security.MessageDigest.getInstance("SHA-256").digest(thumb.first))
            val resources = listOf(
                Resource("o", size, captionMeta(item, Role.ORIGINAL, hash, item.filename, size)) { phone.openOriginal(file) },
                Resource("t", thumb.first.size.toLong(), captionMeta(item, Role.THUMBNAIL, thumbHash, "thumb.jpg", thumb.first.size.toLong())
                    .copy(wh = listOf(thumb.second, thumb.third), m = "image/jpeg")) { thumbFile.inputStream() },
            )
            val streamTotal = resources.sumOf { it.size }
            var before = 0L
            val itemId = item.id
            for (r in resources) {
                coroutineContext.ensureActive()
                val base = before
                val parts = uploader.upload(
                    itemId, r, item.parts[r.role].orEmpty(), item.uploadResume[r.role],
                    checkpoint = { parts, expected, point -> store.update(itemId) { it.withParts(r.role, parts, expected, point) } },
                    progress = { sent, _ -> showLane(laneKey, BackupActivity.Lane(file.filename, minOf(base + sent, streamTotal), streamTotal)) },
                )
                item = (store.item(itemId) ?: item).withParts(r.role, parts, parts.size)
                before += r.size
            }
            item = item.copy(roleHashes = item.roleHashes + mapOf("o" to hash, "t" to thumbHash))
                .reduced(JobEvent.Sent(sizeMatches = item.isCompleteInCloud)).copy(uploadedAt = System.currentTimeMillis())
            store.upsert(listOf(item))
            if (item.status != ItemStatus.BackedUp) return Outcome.Failed
            AppLog.info("Backed up ${item.kind.code} (${item.fileSize shr 10} KB)")
            // The fast version, from the file that's here: the video then plays at once from the cloud. Optional.
            if (prefs.streamingCopies && StreamingCopyPolicy.shouldMake(item)) {
                try { uploadFastVersion(item, laneKey) { out -> FastVersionEncoder.encode(app, file.uri, out) } }
                catch (e: Exception) { if (e is CancellationException) throw e; noteFastVersionFailure(e, item) }
            }
            // A big photo's screen copy, from the file that's here. Optional: a failure never undoes the backup.
            if (ScreenCopyPolicy.shouldMake(item)) {
                try { uploadScreenCopy(item, file, laneKey) } catch (e: Exception) { if (e is CancellationException) throw e; noteScreenCopyFailure(e, item) }
            }
            return Outcome.Uploaded
        } catch (e: Exception) {
            return fail(item, e)
        } finally {
            thumbFile.delete()
            showLane(laneKey, null)
        }
    }

    private suspend fun link(item: LibraryItem, localId: String, twin: LibraryItem) {
        val missing = twin.localId?.let { phone.file(it) == null } ?: true
        store.delete(item.id)
        if (missing) store.upsert(listOf(twin.copy(localId = localId))) else store.addAlias(localId, twin.id)
    }

    private fun captionMeta(item: LibraryItem, role: Role, hash: String, name: String, size: Long): CaptionMeta {
        val kind = when (item.kind) { ItemKind.Video -> Kind.VIDEO; ItemKind.LivePhoto -> Kind.LIVE; ItemKind.Photo -> Kind.PHOTO }
        return CaptionMeta(
            id = item.id, r = role, k = kind, h = hash, n = name, s = size,
            m = item.mimeType?.takeIf { role == Role.ORIGINAL } ?: if (role == Role.THUMBNAIL) "image/jpeg" else null,
            t = item.createdAt?.let { it / 1000 }, tz = item.tzOffsetMinutes,
            g = item.latitude?.let { lat -> item.longitude?.let { lon -> CaptionMeta.roundedGps(lat, lon) } },
            wh = if (item.width > 0) listOf(item.width, item.height) else null,
            d = if (role == Role.THUMBNAIL) null else item.duration, c = item.codec, hdr = item.hdr,
            fav = if (item.favorite) 1 else null, l = item.localId, hid = if (item.hidden) 1 else null,
        )
    }

    /**
     * Uploads an index snapshot (docs/CLOUD_FORMAT.md §7.1) once 500 messages are newer than the last one, so a new
     * phone reads one document instead of the whole channel (iOS `writeSnapshotIfDue`). The older snapshot goes only
     * after the new one is confirmed with its size. Optional: a failure is logged and tried after the next run.
     */
    private suspend fun writeSnapshotIfDue() {
        val chatId = library.chatId ?: return
        val keys = library.keys ?: return
        val items = store.allItems()
        val messages = items.filter { it.hasCloudParts }.flatMap { LibraryIndexer.knownMessages(it, emptySet()) }
        val upto = messages.maxOfOrNull { it.messageId } ?: return
        val lastUpto = store.meta(SNAPSHOT_UPTO)?.toLongOrNull() ?: 0
        if (messages.count { it.messageId > lastUpto } < SNAPSHOT_EVERY) return
        val started = System.currentTimeMillis()
        val file = File(staging.apply { mkdirs() }, "library-index.cge")
        try {
            val body = IndexSnapshot.body(messages, upto)
            val plain = IndexSnapshot.encode(body)
            val caption = IndexSnapshot.caption(IndexSnapshot.captionFor(plain, body), keys.captionKey)
            file.writeBytes(FileCrypto.encrypt(plain, keys.master))
            val size = file.length()
            val message = uploads.sendDocument(chatId, file, caption)
            val doc = (message.content as? org.drinkless.tdlib.TdApi.MessageDocument)?.document?.document
            if (doc == null || doc.size != size) {
                runCatching { uploads.deleteMessages(chatId, listOf(message.id)) }
                return
            }
            val previous = store.meta(SNAPSHOT_MESSAGE)?.toLongOrNull()
            store.setMeta(SNAPSHOT_MESSAGE, message.id.toString())
            store.setMeta(SNAPSHOT_UPTO, upto.toString())
            previous?.let { runCatching { uploads.deleteMessages(chatId, listOf(it)) } }
            uploads.forgetLocalCopy(doc.id)
            AppLog.info("Uploaded the index snapshot: ${body.messages.size} messages, ${size shr 10} KB, in ${(System.currentTimeMillis() - started) / 1000.0} s")
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            (e as? TelegramException)?.let { t -> (TelegramErrorClassifier.classify(t.code, t.message) as? TelegramErrorKind.FloodWait)?.let { holdFor(it.seconds) } }
            AppLog.warn("Index snapshot not uploaded: ${e::class.simpleName}")
        } finally {
            file.delete()
        }
    }

    /** Photos backed up before (or whose copy failed) get one a few at a time at the end of a run, from the phone file. */
    private suspend fun makeEarlierScreenCopies(limit: Int = 20) {
        val candidates = store.items(ItemStatus.BackedUp).filter { it.localId != null && it.hasCloudParts && ScreenCopyPolicy.shouldMake(it) }
        if (candidates.isEmpty()) return
        val files = phone.files(candidates.mapNotNull { it.localId })
        var made = 0
        for (item in candidates) {
            if (made >= limit || blocker() != null) break
            val file = files[item.localId] ?: continue
            waitForFloodPause()
            acquireLaneSlot()
            try {
                paceUploadStart()
                if (uploadScreenCopy(item, file, "copy")) made++
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                noteScreenCopyFailure(e, item)
                if (e is TelegramException && TelegramErrorClassifier.classify(e.code, e.message) is TelegramErrorKind.FloodWait) break
            } finally {
                synchronized(gate) { slots.release() }
            }
        }
        if (made > 0) AppLog.info("Made screen copies for $made earlier photo${if (made == 1) "" else "s"}")
    }

    /** Uploads the screen copy as role `d`; false (and never tried again) when it wouldn't be much smaller. */
    private suspend fun uploadScreenCopy(item: LibraryItem, file: PhoneFile, laneKey: String): Boolean {
        val chatId = library.chatId ?: throw LibraryException.notALibrary
        val label = "${item.filename} (screen copy)"
        showLane(laneKey, BackupActivity.Lane(label, 0, 0))
        val out = File(staging.apply { mkdirs() }, "${item.id}-screen.jpg")
        try {
            // Parts of an earlier, interrupted copy: a new encode isn't byte-identical, so start over.
            item.parts["d"]?.takeIf { it.isNotEmpty() }?.let { stale ->
                uploads.deleteMessages(chatId, stale.map { it.messageId })
                store.update(item.id) { it.copy(parts = it.parts - "d", expectedParts = it.expectedParts - "d", uploadResume = it.uploadResume - "d") }
            }
            val (copy, w, h) = phone.screenCopy(file, out)
            val size = copy.length()
            if (!ScreenCopyPolicy.isWorthKeeping(size, item.fileSize)) {
                store.update(item.id) { it.copy(screenCopySkipped = true) }
                AppLog.info("No screen copy for ${item.filename}: ${size shr 10} KB isn't much smaller than ${item.fileSize shr 10} KB")
                return false
            }
            val hash = PhoneFiles.hex(java.security.MessageDigest.getInstance("SHA-256").digest(copy.readBytes()))
            val name = item.filename.substringBeforeLast('.') + "-screen.jpg"
            val meta = captionMeta(item, Role.SCREEN_COPY, hash, name, size).copy(wh = listOf(w, h), m = "image/jpeg")
            val parts = uploader.upload(
                item.id, Resource("d", size, meta) { copy.inputStream() }, emptyList(), null,
                checkpoint = { p, expected, _ -> store.update(item.id) { it.withParts("d", p, expected) } },
                progress = { sent, total -> showLane(laneKey, BackupActivity.Lane(label, sent, total)) },
            )
            store.update(item.id) { it.withParts("d", parts, parts.size).copy(screenCopySkipped = false, roleHashes = it.roleHashes + ("d" to hash)) }
            AppLog.info("Uploaded a screen copy: ${size shr 10} KB for a ${item.fileSize shr 10} KB photo")
            return true
        } finally {
            out.delete()
            showLane(laneKey, null)
        }
    }

    /**
     * "Make fast version" in the viewer: the fast version of one video, now, from the phone's file or, for a video
     * that's only in the cloud, from its original downloaded first (the user asked for it).
     */
    suspend fun makeFastVersion(itemId: String) = withContext(Dispatchers.IO) {
        val item = store.item(itemId) ?: throw FastVersionUnsupported("gone")
        if (item.status != ItemStatus.BackedUp || item.kind != ItemKind.Video) throw FastVersionUnsupported("not a backed-up video")
        if (StreamingCopyPolicy.hasCopy(item)) return@withContext
        val file = item.localId?.let(phone::file)
        if (file != null) {
            uploadFastVersion(item, "copy", force = true) { out -> FastVersionEncoder.encode(app, file.uri, out) }
            return@withContext
        }
        val source = File(staging.apply { mkdirs() }, "${item.id}-source.${item.filename.substringAfterLast('.', "mp4")}")
        try {
            reader.download(item, "o", source)
            uploadFastVersion(item, "copy", force = true) { out -> FastVersionEncoder.encode(app, android.net.Uri.fromFile(source), out) }
        } finally {
            source.delete()
        }
    }

    /** Encodes with [encode] and uploads as role `sp`; false (never tried again) when it wouldn't be much smaller. */
    private suspend fun uploadFastVersion(item: LibraryItem, laneKey: String, force: Boolean = false, encode: suspend (File) -> FastVersionEncoder.Result): Boolean {
        val chatId = library.chatId ?: throw LibraryException.notALibrary
        val label = "${item.filename} (fast version)"
        showLane(laneKey, BackupActivity.Lane(label, 0, 0))
        val out = File(staging.apply { mkdirs() }, "${item.id}-fast.mp4")
        try {
            // Parts of an earlier, interrupted copy: a new encode isn't byte-identical, so start over.
            item.parts["sp"]?.takeIf { it.isNotEmpty() }?.let { stale ->
                uploads.deleteMessages(chatId, stale.map { it.messageId })
                store.update(item.id) { it.copy(parts = it.parts - "sp", expectedParts = it.expectedParts - "sp", uploadResume = it.uploadResume - "sp") }
            }
            val started = System.currentTimeMillis()
            val copy = encode(out)
            val size = copy.file.length()
            if (!force && !StreamingCopyPolicy.isWorthKeeping(size, item.fileSize)) {
                store.update(item.id) { it.copy(streamingCopySkipped = true) }
                AppLog.info("No fast version for ${item.filename}: ${size shr 10} KB isn't much smaller than ${item.fileSize shr 10} KB")
                return false
            }
            AppLog.info("Made a fast version (${copy.codec}, ${copy.width}×${copy.height}) in ${(System.currentTimeMillis() - started) / 1000} s")
            val hash = PhoneFiles.hex(java.security.MessageDigest.getInstance("SHA-256").let { d ->
                copy.file.inputStream().use { s -> val b = ByteArray(1 shl 20); while (true) { val n = s.read(b); if (n < 0) break; d.update(b, 0, n) } }
                d.digest()
            })
            val name = item.filename.substringBeforeLast('.') + "-fast.mp4"
            val meta = captionMeta(item, Role.SMOOTH_PREVIEW, hash, name, size)
                .copy(wh = listOf(copy.width, copy.height), c = copy.codec, hdr = null, m = "video/mp4")
            val parts = uploader.upload(
                item.id, Resource("sp", size, meta) { copy.file.inputStream() }, emptyList(), null,
                checkpoint = { p, expected, _ -> store.update(item.id) { it.withParts("sp", p, expected) } },
                progress = { sent, total -> showLane(laneKey, BackupActivity.Lane(label, sent, total)) },
            )
            store.update(item.id) { it.withParts("sp", parts, parts.size).copy(streamingCopySkipped = false, roleHashes = it.roleHashes + ("sp" to hash)) }
            AppLog.info("Uploaded a fast version: ${size shr 10} KB for a ${item.fileSize shr 10} KB original")
            return true
        } finally {
            out.delete()
            showLane(laneKey, null)
        }
    }

    /** A fast version is optional: only a video that can't be converted at all is left alone from then on. */
    private suspend fun noteFastVersionFailure(e: Exception, item: LibraryItem) {
        if (e is TelegramException) {
            (TelegramErrorClassifier.classify(e.code, e.message) as? TelegramErrorKind.FloodWait)?.let { holdFor(it.seconds) }
            AppLog.warn("Fast version of ${item.filename} will be retried: ${e.message}")
            return
        }
        if (e is FastVersionUnsupported) store.update(item.id) { it.copy(streamingCopySkipped = true) }
        AppLog.warn("No fast version for ${item.filename}${if (e is FastVersionUnsupported) "" else " yet"}: ${e::class.simpleName} ${e.message ?: ""}")
    }

    /** A screen copy is optional: only a photo that can't be decoded is left alone from then on. */
    private suspend fun noteScreenCopyFailure(e: Exception, item: LibraryItem) {
        if (e is TelegramException) {
            (TelegramErrorClassifier.classify(e.code, e.message) as? TelegramErrorKind.FloodWait)?.let { holdFor(it.seconds) }
            AppLog.warn("Screen copy of ${item.filename} will be retried: ${e.message}")
            return
        }
        if (e is ScreenCopyUnreadable) store.update(item.id) { it.copy(screenCopySkipped = true) }
        AppLog.warn("No screen copy for ${item.filename}${if (e is ScreenCopyUnreadable) "" else " yet"}: ${e::class.simpleName}")
    }

    private suspend fun fail(start: LibraryItem, e: Exception): Outcome {
        var item = store.item(start.id) ?: start
        if (e is CancellationException) {
            withContext(kotlinx.coroutines.NonCancellable) { store.upsert(listOf(item.reduced(JobEvent.Interrupted))) }
            throw e
        }
        val kind: TelegramErrorKind = when (e) {
            is TelegramException -> TelegramErrorClassifier.classify(e.code, e.message)
            is UploadStalledException -> TelegramErrorKind.Transient
            // A retry in this run would read the file again and fail the same way.
            is NotEnoughSpaceException, is OriginalUnavailableException, is LibraryException, is CryptoException, is SizeMismatchException -> TelegramErrorKind.Permanent
            else -> TelegramErrorKind.Transient
        }
        val reason = when (e) {
            is TelegramException -> TelegramErrors.friendly(e.code, e.message)
            else -> e.message ?: "The upload failed."
        }
        // Changed while it was read: hash it again next time.
        if (e is FileChangedException) item = item.copy(sha256 = "", assetModifiedAt = null)
        item = when (kind) {
            is TelegramErrorKind.FloodWait -> { holdFor(kind.seconds); item.reduced(JobEvent.FloodWait(kind.seconds)) }
            TelegramErrorKind.Transient -> item.reduced(JobEvent.Error(reason, transient = true))
            TelegramErrorKind.Auth, TelegramErrorKind.Permanent -> item.reduced(JobEvent.Error(reason, transient = false))
        }
        store.upsert(listOf(item))
        return if (item.status == ItemStatus.Failed) {
            AppLog.error("Upload of ${item.filename} failed: ${e::class.simpleName}: $reason")
            Outcome.Failed
        } else {
            AppLog.info("Upload of ${item.filename} will be retried: ${e::class.simpleName}")
            Outcome.RetryLater
        }
    }

    private class Counter {
        private var uploaded = 0; private var duplicate = 0; private var failed = 0; private var done = 0

        @Synchronized fun record(o: Outcome): Pair<Int, Triple<Int, Int, Int>> {
            when (o) {
                Outcome.Uploaded -> uploaded++
                Outcome.Duplicate -> duplicate++
                Outcome.Failed -> failed++
                Outcome.Skipped, Outcome.RetryLater -> Unit
            }
            done++
            return done to Triple(uploaded, duplicate, failed)
        }

        @Synchronized fun snapshot() = Triple(uploaded, duplicate, failed)
    }

    companion object {
        const val MAX_CONCURRENT_UPLOADS = 2
        const val UPLOAD_SPACING_MS = 1_500L
        const val SNAPSHOT_EVERY = 500
        const val SNAPSHOT_UPTO = "snapshotUpto"
        const val SNAPSHOT_MESSAGE = "snapshotMessageId"
    }
}
