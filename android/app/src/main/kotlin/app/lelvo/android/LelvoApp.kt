package app.lelvo.android

import android.app.Application
import app.lelvo.android.background.BackupScheduler
import app.lelvo.android.background.BackupTileService
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import android.os.Build
import android.util.Log
import app.lelvo.core.support.AppLog
import app.lelvo.data.CoreCheck
import app.lelvo.data.DemoMode
import app.lelvo.data.LibraryScanner
import app.lelvo.data.Prefs
import app.lelvo.data.LibraryService
import app.lelvo.data.index.IndexDatabase
import app.lelvo.data.index.LibraryStore
import coil3.ImageLoader
import coil3.PlatformContext
import coil3.SingletonImageLoader
import coil3.imageDecoderEnabled
import coil3.video.VideoFrameDecoder
import app.lelvo.data.SecretStore
import app.lelvo.telegram.AuthStep
import app.lelvo.telegram.TdClient
import app.lelvo.telegram.TdFiles
import app.lelvo.telegram.TelegramConfig
import java.util.Locale
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Creates the services once per process; screens and background work share them (like iOS AppEnvironment). */
class LelvoApp : Application(), SingletonImageLoader.Factory {
    lateinit var secrets: SecretStore private set
    lateinit var telegram: TdClient private set
    lateinit var library: LibraryService private set
    lateinit var store: LibraryStore private set
    lateinit var demo: DemoMode private set
    lateinit var prefs: Prefs private set
    lateinit var files: TdFiles private set
    lateinit var scanner: LibraryScanner private set
    lateinit var coreCheck: CoreCheck private set
    lateinit var model: AppModel private set
    lateinit var photos: app.lelvo.data.media.PhotoAccess private set
    lateinit var linker: app.lelvo.data.media.PhotoLinker private set
    lateinit var reader: app.lelvo.data.media.MediaReader private set
    lateinit var media: app.lelvo.data.media.CloudMedia private set
    lateinit var positions: app.lelvo.data.media.PlaybackPositions private set
    lateinit var saver: app.lelvo.data.media.PhoneSaver private set
    lateinit var details: app.lelvo.data.media.MediaDetailsReader private set
    lateinit var motion: app.lelvo.data.media.MotionVideos private set
    lateinit var search: app.lelvo.data.search.SearchService private set
    lateinit var uploads: app.lelvo.telegram.TdUploads private set
    lateinit var backup: app.lelvo.data.backup.BackupEngine private set
    lateinit var freeUpSpace: app.lelvo.data.backup.FreeUpSpaceService private set
    lateinit var duplicates: app.lelvo.data.backup.Duplicates private set
    lateinit var similar: app.lelvo.data.backup.SimilarPhotosService private set
    lateinit var secondCopy: app.lelvo.data.backup.SecondCopyService private set
    lateinit var sync: app.lelvo.data.sync.NoteSync private set
    lateinit var choices: app.lelvo.data.sync.LibraryChoices private set
    /** The launch opening plays once per process (cold start only). */
    var openingPlayed = false
    private var startedActivities = 0
    /** An activity of Lelvo is on screen; background runs then leave the summary to the app. */
    val isOnScreen: Boolean get() = startedActivities > 0

    override fun onCreate() {
        super.onCreate()
        // Logs stay out of Android backup, like the secrets; only the user shares them (Settings → Logs).
        AppLog.install(
            dir = java.io.File(noBackupFilesDir, "logs"),
            secrets = { listOf(BuildConfig.TELEGRAM_API_HASH).filter { it.isNotBlank() } },
            // Debug builds echo to logcat, like iOS prints to the device console in Debug.
            echo = if (BuildConfig.DEBUG) { level, line ->
                when (level) {
                    AppLog.Level.INFO -> Log.i("Lelvo", line)
                    AppLog.Level.WARN -> Log.w("Lelvo", line)
                    AppLog.Level.ERROR -> Log.e("Lelvo", line)
                }
            } else null,
        )
        CrashReports.install(this)
        secrets = SecretStore(this)
        val config = BuildConfig.TELEGRAM_API_ID.takeIf { it != 0 && BuildConfig.TELEGRAM_API_HASH.isNotBlank() }?.let {
            TelegramConfig(
                apiId = it,
                apiHash = BuildConfig.TELEGRAM_API_HASH,
                useTestDc = BuildConfig.TELEGRAM_TEST_DC,
                dataDir = noBackupFilesDir,
                cacheDir = cacheDir,
                // Shown in Telegram → Settings → Devices.
                deviceModel = "Android",
                appVersion = BuildConfig.VERSION_NAME,
                languageCode = Locale.getDefault().language.ifBlank { "en" },
            )
        }
        telegram = TdClient(config, secrets.telegramDatabaseKeys())
        telegram.start()
        library = LibraryService(this, telegram, secrets)
        store = LibraryStore(IndexDatabase.open(this))
        demo = DemoMode(this, store)
        prefs = Prefs(this)
        files = TdFiles(telegram)
        scanner = LibraryScanner(files, library, store, telegram).also { it.follow() }
        coreCheck = CoreCheck(files, library, scanner, store)
        photos = app.lelvo.data.media.PhotoAccess(this)
        linker = app.lelvo.data.media.PhotoLinker(store, photos)
        reader = app.lelvo.data.media.MediaReader(files, library, telegram)
        media = app.lelvo.data.media.CloudMedia(this, reader, prefs)
        positions = app.lelvo.data.media.PlaybackPositions(this)
        saver = app.lelvo.data.media.PhoneSaver(this, reader, store)
        details = app.lelvo.data.media.MediaDetailsReader(this)
        motion = app.lelvo.data.media.MotionVideos(this)
        search = app.lelvo.data.search.SearchService(this, store, photos)
        uploads = app.lelvo.telegram.TdUploads(telegram, files)
        backup = app.lelvo.data.backup.BackupEngine(this, store, library, scanner, uploads, photos, linker, prefs, reader)
        freeUpSpace = app.lelvo.data.backup.FreeUpSpaceService(store, library, scanner, uploads, backup.phone)
        duplicates = app.lelvo.data.backup.Duplicates(store, library, scanner, uploads, backup.phone)
        similar = app.lelvo.data.backup.SimilarPhotosService(this, store, photos, media)
        secondCopy = app.lelvo.data.backup.SecondCopyService(this, store, reader)
        choices = app.lelvo.data.sync.LibraryChoices(java.io.File(noBackupFilesDir, "choices"))
        scanner.choices = choices
        sync = app.lelvo.data.sync.NoteSync(this, store, library, scanner, files, uploads, backup, telegram, photos, isDemo = { demo.active.value })
        model = AppModel(this)
        // Shared cloud photos from the last run (Copy's stay: the clipboard may still point at them).
        Thread { java.io.File(cacheDir, "Share").deleteRecursively() }.start()
        registerActivityLifecycleCallbacks(object : ActivityLifecycleCallbacks {
            override fun onActivityStarted(activity: android.app.Activity) {
                // Lelvo comes to the front (iOS scene `.active`): follow the other devices, send what's waiting.
                if (startedActivities++ == 0 && library.setupFinished) sync.onOpen { linker.relink() }
            }
            override fun onActivityStopped(activity: android.app.Activity) {
                startedActivities = maxOf(0, startedActivities - 1)
                // To the background (iOS `.background`): changes go now, not after the pacing.
                if (startedActivities == 0) sync.onBackground()
            }
            override fun onActivityCreated(activity: android.app.Activity, savedInstanceState: android.os.Bundle?) {}
            override fun onActivityResumed(activity: android.app.Activity) {}
            override fun onActivityPaused(activity: android.app.Activity) {}
            override fun onActivitySaveInstanceState(activity: android.app.Activity, outState: android.os.Bundle) {}
            override fun onActivityDestroyed(activity: android.app.Activity) {}
        })
        // The Quick Settings tile follows the backup: started, an item done, finished.
        kotlinx.coroutines.MainScope().launch {
            backup.activity.map { Triple(it.isRunning, it.done, it.total) }.distinctUntilChanged().collect { BackupTileService.update(this@LelvoApp) }
        }
        if (library.isConfigured && library.setupFinished) BackupScheduler.schedule(this, prefs)
        // Every cache within its limit once Telegram is up, TDLib's files too (iOS does this at launch).
        kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + Dispatchers.IO).launch {
            telegram.auth.first { it == AuthStep.Ready }
            media.enforceLimits()
        }
    }

    /**
     * Back up now, Back up on chosen photos, Retry, the shortcut and the tile: a user run, which keeps going with Lelvo
     * in the background (its notification shows progress). [includeNew]: every photo not yet in the cloud.
     */
    fun startBackup(includeNew: Boolean) {
        prefs.backupPaused = false
        BackupScheduler.startNow(this, includeNew)
    }

    /** Pause backup (the Backup tab, the notification, the tile): stops the run and the user runs queued after it. */
    fun pauseBackup() {
        BackupScheduler.cancelUserRuns(this)
        backup.pause()
    }

    /**
     * Sign out and reset, like iOS `AppEnvironment.resetEverything`: Telegram signs out (TDLib removes its own data),
     * then the index, the library's keys, the cached images and every setting go. The channel isn't touched.
     * [keepingChoices]: the user didn't ask (the session ended elsewhere). This library's choices (deleted for good,
     * changes not sent yet) are kept for the next sign-in then (iOS `LibrarySnapshots.saveChoices`).
     */
    suspend fun resetEverything(keepingChoices: Boolean) {
        // Waiting changes get a moment (iOS `sendBeforeLeaving`); after a sign out the photos stay normal backups on
        // the other devices, which keeps data.
        if (!keepingChoices) sync.sendBeforeLeaving()
        if (backup.isRunning) backup.pause()
        BackupScheduler.cancelAll(this)
        AppLog.info("Reset this phone: signing out and removing Lelvo's local data${if (keepingChoices) " (session ended elsewhere)" else ""}")
        demo.exit()
        // Telegram is asked only when a session or a sign-in is under way; in the demo it usually isn't.
        if (telegram.auth.value !in listOf(AuthStep.WaitPhone, AuthStep.NeedsCredentials, AuthStep.Closed)) telegram.logOut()
        withContext(Dispatchers.IO) {
            // Signing in again after the session ended elsewhere must not undo deletes or back up deleted photos again.
            val chat = library.chatId
            if (keepingChoices && chat != null) choices.save(chat, store) else if (!keepingChoices) choices.removeAll()
            store.deleteAll()
            library.forget()
            prefs.reset()
            SingletonImageLoader.get(this@LelvoApp).let { it.memoryCache?.clear(); it.diskCache?.clear() }
            media.clear()
            motion.clear()
            search.clear()
            app.lelvo.android.search.forgetSearchIndex()
            positions.clear()
        }
        AppLog.info("Reset finished")
    }

    // Video cells show their first frame.
    override fun newImageLoader(context: PlatformContext): ImageLoader =
        ImageLoader.Builder(context).components {
            add(VideoFrameDecoder.Factory())
            add(app.lelvo.android.media.CloudImageFetcher.ThumbnailFactory(media))
            add(app.lelvo.android.media.CloudImageFetcher.PhotoFactory(media))
            add(app.lelvo.android.media.CloudThumbnailKeyer())
            add(app.lelvo.android.media.CloudPhotoKeyer())
            add(app.lelvo.android.media.PhoneThumbnailFetcher.Factory(this@LelvoApp))
            add(app.lelvo.android.media.PhoneThumbnailKeyer())
        }
            // Android's ImageDecoder refuses many iPhone HEIC photos ("getPixels failed with error invalid input"), so
            // those never turned sharp in the viewer. BitmapFactory decodes the same files, as does the zoom's tiling.
            .imageDecoderEnabled(false)
            .build()

    /** "First Last" of the signed-in account, as Settings shows it; empty when Telegram can't say. */
    suspend fun accountName(): String = runCatching {
        val me = telegram.send(org.drinkless.tdlib.TdApi.GetMe())
        listOf(me.firstName, me.lastName).filter { it.isNotBlank() }.joinToString(" ")
    }.getOrDefault("")

    /** On a metered network (mobile data): nothing is fetched ahead, like iOS on an expensive network. */
    fun isMetered(): Boolean =
        runCatching { getSystemService(android.net.ConnectivityManager::class.java).isActiveNetworkMetered }.getOrDefault(true)

    /** The library channel's name. */
    suspend fun libraryTitle(): String = runCatching {
        val chatId = library.chatId ?: return ""
        // After a restart TDLib knows the channel only once it's loaded.
        files.ensureChat(chatId)
        telegram.send(org.drinkless.tdlib.TdApi.GetChat(chatId)).title
    }.getOrDefault("")
}
