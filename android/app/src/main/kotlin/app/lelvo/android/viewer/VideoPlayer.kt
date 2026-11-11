package app.lelvo.android.viewer

import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import android.net.Uri
import androidx.annotation.OptIn
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.material3.TextButton
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.Canvas
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.SeekParameters
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import app.lelvo.android.LelvoApp
import app.lelvo.android.R
import app.lelvo.android.media.CloudDataSource
import app.lelvo.android.media.VideoDecoders
import app.lelvo.core.index.LibraryItem
import app.lelvo.core.support.AppLog
import app.lelvo.core.video.VideoLabels
import app.lelvo.core.video.VideoNavigation
import app.lelvo.core.video.VideoPreference
import app.lelvo.core.video.VideoQualityPolicy
import app.lelvo.core.video.VideoVersion
import app.lelvo.core.video.hasFastVersion
import app.lelvo.data.DemoMode
import app.lelvo.data.Prefs
import app.lelvo.data.media.MediaException
import coil3.compose.AsyncImage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * One video in the viewer: its player, what the controls show, and for a cloud video which version plays (iOS
 * `CloudVideoSession` and `PlaybackState`). With Automatic quality, a stall of a few seconds on the original switches
 * to the fast version, never against the user's own pick.
 */
@OptIn(UnstableApi::class)
@Stable
internal class VideoSession(
    val player: ExoPlayer,
    private val app: LelvoApp,
    /** Null for a phone or demo video: it has one version. */
    val item: LibraryItem?,
    private val scope: CoroutineScope,
) {
    var playing by mutableStateOf(false)
    /** Play was asked for (it may still be loading): the button then offers Pause. */
    var wantsPlay by mutableStateOf(true)
    var ended by mutableStateOf(false)
    var buffering by mutableStateOf(true)
    var firstFrame by mutableStateOf(false)
    /** The picture is on screen in its real shape; stays true through a quality switch (the last frame shows on). */
    var shown by mutableStateOf(false)
    var position by mutableFloatStateOf(0f)
    /** How far the video is loaded, in seconds: drawn lighter on the scrubber, like Google Photos. */
    var buffered by mutableFloatStateOf(0f)
    var duration by mutableFloatStateOf(item?.duration?.toFloat() ?: 0f)
    var muted by mutableStateOf(false)
    var speed by mutableFloatStateOf(1f)
    var error by mutableStateOf<String?>(null)
    var version by mutableStateOf(VideoVersion.Original)
    var switching by mutableStateOf(false)
    private var userChose = false
    private var stall: Job? = null
    /** When the version on screen was asked for: opening, or the last quality switch. */
    private var opened = System.currentTimeMillis()
    private val preference = when (app.prefs.videoQuality) {
        Prefs.VideoQuality.Original -> VideoPreference.Original
        Prefs.VideoQuality.Fast -> VideoPreference.Fast
        Prefs.VideoQuality.Automatic -> VideoPreference.Automatic
    }

    val hasFast: Boolean get() = item?.hasFastVersion == true

    /** This phone can decode the original smoothly (`VideoDecoders.canPlay`); asked once per video. */
    val originalPlayable: Boolean = item == null || VideoDecoders.canPlay(item.codec, item.width, item.height)

    /** "4K" / "1080p" when the two versions differ in resolution; otherwise "Original" / "Fast" (iOS `VideoQualityMenu`). */
    fun label(v: VideoVersion): String? {
        val i = item ?: return null
        val mine = VideoLabels.resolution(i.width, i.height, v) ?: return null
        val other = VideoLabels.resolution(i.width, i.height, if (v == VideoVersion.Original) VideoVersion.Fast else VideoVersion.Original)
        return mine.takeIf { it != other }
    }

    /** Frames for the scrubber, made the first time it's dragged. */
    val strip = FrameStrip(scope)
    private var localUri: Uri? = null

    /** Loads the strip, from the fast version where there is one: smaller, so its keyframes cost less to reach. */
    fun loadStrip() {
        val source = localUri?.let { FrameStrip.Source.Local(it) }
            ?: item?.let { FrameStrip.Source.Cloud(app.reader, it, if (hasFast) "sp" else app.media.displayedRole(it)) }
            ?: return
        strip.load(app, source, duration.toDouble())
    }

    fun start(phone: Uri?) {
        val demo = item?.let(DemoMode::assetUri)
        localUri = phone ?: demo?.let(Uri::parse)
        when {
            phone != null -> player.setMediaItem(MediaItem.fromUri(phone))
            demo != null -> player.setMediaItem(MediaItem.fromUri(demo))
            item != null -> {
                version = VideoQualityPolicy.initial(preference, hasFast, originalPlayable)
                player.setMediaSource(source(item, version))
                VideoNavigation.resumePosition(app.positions.position(item.id), item.duration ?: 0.0)?.let { player.seekTo((it * 1000).toLong()) }
            }
        }
        player.addListener(object : Player.Listener {
            override fun onRenderedFirstFrame() {
                if (firstFrame) return
                AppLog.info("Video timing: ${source()}, first frame after ${System.currentTimeMillis() - opened} ms")
                // The first frame can arrive before the view has taken the video's shape, and then showed stretched
                // across the whole screen for a moment. Two frames later the layout has caught up.
                firstFrame = true
                scope.launch {
                    delay(34)
                    shown = true
                }
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) { playing = isPlaying }

            override fun onPlaybackStateChanged(state: Int) {
                buffering = state == Player.STATE_BUFFERING || state == Player.STATE_IDLE
                ended = state == Player.STATE_ENDED
                if (player.duration > 0) duration = player.duration / 1000f
                watchStall()
            }

            override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
                wantsPlay = playWhenReady
                watchStall()
            }

            override fun onPlayerError(e: PlaybackException) {
                error = (generateSequence<Throwable>(e) { it.cause }.firstOrNull { it is MediaException } as? MediaException)?.message
                    ?: "This video can't play right now. Check your connection and try again."
                AppLog.warn("Video: ${source()} failed: ${e.errorCodeName}")
            }
        })
        player.prepare()
        player.playWhenReady = true
    }

    fun describe(): String = source()

    private fun source(): String = when {
        item == null -> "phone video"
        DemoMode.assetUri(item) != null -> "demo"
        version == VideoVersion.Fast -> "fast version"
        else -> "original"
    }

    private fun source(item: LibraryItem, v: VideoVersion): MediaSource {
        val role = if (v == VideoVersion.Fast) "sp" else app.media.displayedRole(item)
        return ProgressiveMediaSource.Factory(CloudDataSource.Factory(app.reader, item, role))
            .createMediaSource(MediaItem.fromUri("lelvo://item/${item.id}/$role"))
    }

    /** The original waiting for data while it should play: after a few seconds, the fast version takes over. */
    private fun watchStall() {
        stall?.cancel()
        val waiting = player.playWhenReady && player.playbackState == Player.STATE_BUFFERING
        if (!waiting || switching || !VideoQualityPolicy.fallsBackOnStall(version, preference, hasFast, userChose)) return
        stall = scope.launch {
            delay((VideoQualityPolicy.STALL_SECONDS_BEFORE_FALLBACK * 1000).toLong())
            if (player.playbackState != Player.STATE_BUFFERING) return@launch
            AppLog.info("Video quality: stalled for ${VideoQualityPolicy.STALL_SECONDS_BEFORE_FALLBACK.toInt()} s on the original")
            switchTo(VideoVersion.Fast)
        }
    }

    /** From the quality menu: never switch on our own after that. */
    fun choose(v: VideoVersion) {
        userChose = true
        switchTo(v)
    }

    /** Swaps the version at the same moment, playing on if it was playing. */
    private fun switchTo(v: VideoVersion) {
        val item = item ?: return
        if (v == version || switching || (v == VideoVersion.Fast && !hasFast)) return
        switching = true
        stall?.cancel()
        val at = player.currentPosition
        version = v
        firstFrame = false
        opened = System.currentTimeMillis()
        player.setMediaSource(source(item, v), at)
        player.prepare()
        AppLog.info("Video quality: switched to the ${if (v == VideoVersion.Fast) "fast version" else "original"} at ${"%.1f".format(at / 1000.0)} s")
        scope.launch {
            // Done once the new version shows a picture or can play.
            while (!firstFrame && player.playbackState == Player.STATE_BUFFERING) delay(100)
            switching = false
        }
    }

    /** At the end, Play starts again from the beginning (it used to pause there). */
    fun togglePlay() {
        if (player.playbackState == Player.STATE_ENDED) {
            player.seekTo(0)
            player.playWhenReady = true
            return
        }
        player.playWhenReady = !player.playWhenReady
    }

    fun toggleMute() {
        muted = !muted
        player.volume = if (muted) 0f else 1f
    }

    fun setRate(s: Float) {
        speed = s
        player.setPlaybackSpeed(s)
    }

    fun skip(by: Double) {
        val to = VideoNavigation.skipTarget(player.currentPosition / 1000.0, duration.toDouble(), by)
        player.seekTo((to * 1000).toLong())
        position = to.toFloat()
    }

    /** While the scrubber moves: the nearest keyframe, which shows at once. */
    fun scrub(seconds: Float) {
        player.setSeekParameters(SeekParameters.CLOSEST_SYNC)
        player.seekTo((seconds * 1000).toLong())
    }

    /**
     * Where the scrubber was let go. Landing up to half a second early on a keyframe shows the picture at once; an
     * exact frame would first need everything from the keyframe before it, which may still be downloading (iOS seek).
     */
    fun seekEnded(seconds: Float) {
        player.setSeekParameters(SeekParameters(500_000, 0))
        player.seekTo((seconds * 1000).toLong())
        position = seconds
    }

    fun release() {
        stall?.cancel()
        strip.cancel()
        val item = item
        if (item != null && DemoMode.assetUri(item) == null) {
            val d = if (player.duration > 0) player.duration / 1000.0 else item.duration ?: 0.0
            app.positions.record(item.id, player.currentPosition / 1000.0, d)
        }
        player.release()
    }
}

/**
 * A video page: the picture and a poster until its first frame; the controls (play, scrubber, times, speed, sound)
 * sit in the viewer's bottom panel ([VideoControls]). A tap shows or hides the bars; a double tap on either side
 * skips 10 seconds, in the middle it plays or pauses.
 * The sound stops when the page or the viewer goes away (iOS #115) and when the app leaves the screen.
 */
@OptIn(UnstableApi::class)
@Composable
internal fun VideoPage(
    key: String, phone: Uri?, item: LibraryItem?, poster: Any, chrome: Boolean, onTap: () -> Unit, onSession: (VideoSession?) -> Unit,
) {
    val context = LocalContext.current
    val app = context.applicationContext as LelvoApp
    val scope = rememberCoroutineScope()
    val session = remember(key) {
        val player = ExoPlayer.Builder(context, VideoDecoders.renderers(context))
            // Another app's sound pauses it, and so do headphones coming out, like any Android player.
            .setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(), true)
            .setHandleAudioBecomingNoisy(true)
            // Start once half a second is buffered, not Media3's 2.5 s: Telegram delivers a fast version two to four
            // times faster than it plays, so it keeps ahead (iOS `startSoon`). A stall later waits for 1.5 s.
            .setLoadControl(
                DefaultLoadControl.Builder()
                    .setBufferDurationsMs(15_000, 50_000, 500, 1_500)
                    .build(),
            )
            .build()
        VideoSession(player, app, item, scope).also {
            player.addAnalyticsListener(VideoDecoders.logging { it.describe() })
            it.start(phone)
        }
    }
    DisposableEffect(session) {
        onSession(session)
        onDispose { onSession(null); session.release() }
    }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle, session) {
        val observer = LifecycleEventObserver { _, e ->
            when (e) {
                Lifecycle.Event.ON_STOP -> session.player.pause()
                // Back on screen the surface is new and empty: a paused video showed black until played. Seeking to
                // where it is draws that frame again.
                Lifecycle.Event.ON_START -> if (!session.player.playWhenReady) session.player.seekTo(session.player.currentPosition)
                else -> Unit
            }
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(session) {
        while (true) {
            session.position = session.player.currentPosition / 1000f
            session.buffered = session.player.bufferedPosition / 1000f
            delay(250)
        }
    }
    var skipped by remember { mutableStateOf<Pair<Int, Long>?>(null) }

    Box(Modifier.fillMaxSize()) {
        AndroidView(
            factory = {
                (android.view.LayoutInflater.from(it).inflate(R.layout.video_surface, null) as PlayerView).apply {
                    // The backup knows the video's shape: the view takes it before any frame arrives.
                    if (item != null && item.width > 0 && item.height > 0) {
                        findViewById<AspectRatioFrameLayout>(androidx.media3.ui.R.id.exo_content_frame)?.setAspectRatio(item.width.toFloat() / item.height)
                    }
                    this.player = session.player
                }
            },
            // Hidden until its first frame has its real shape; the poster shows meanwhile (it leaves see-through bars
            // around a portrait or landscape picture, where a stretched frame showed through).
            update = { it.alpha = if (session.shown) 1f else 0f },
            modifier = Modifier.fillMaxSize(),
        )
        if (!session.shown) {
            AsyncImage(poster, null, contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize())
        }
        // Taps over the whole picture: one shows or hides the bars, two on a side skip.
        Box(
            Modifier.fillMaxSize().pointerInput(session) {
                detectTapGestures(
                    onTap = { onTap() },
                    onDoubleTap = { p ->
                        val side = when {
                            p.x < size.width / 3f -> -1
                            p.x > size.width * 2 / 3f -> 1
                            else -> 0
                        }
                        if (side == 0) session.togglePlay() else {
                            session.skip(side * VideoNavigation.SKIP)
                            skipped = side to System.nanoTime()
                        }
                    },
                )
            }.semantics { contentDescription = "Video" },
        )
        if ((session.buffering || session.switching) && session.wantsPlay && !session.playing && session.error == null) {
            CircularProgressIndicator(
                color = Color.White, strokeWidth = 3.dp,
                modifier = Modifier.align(Alignment.Center).size(64.dp).background(Color.Black.copy(alpha = 0.35f), CircleShape).padding(16.dp),
            )
        } else if (chrome && session.error == null && (!session.wantsPlay || session.ended)) {
            // Only while paused, like Google Photos: a playing video keeps its picture clear.
            IconButton(
                onClick = session::togglePlay,
                modifier = Modifier.align(Alignment.Center).size(72.dp).background(Color.Black.copy(alpha = 0.45f), CircleShape),
            ) {
                Icon(painterResource(R.drawable.ic_play), "Play", tint = Color.White, modifier = Modifier.size(40.dp))
            }
        }
        skipped?.let { (side, id) ->
            LaunchedEffect(id) { delay(600); skipped = null }
            SkipFeedback(side, Modifier.align(if (side < 0) Alignment.CenterStart else Alignment.CenterEnd))
        }
        session.error?.let { ViewerNotice(it, Modifier.align(Alignment.Center)) }
    }
}

@Composable
private fun SkipFeedback(side: Int, modifier: Modifier) {
    Box(modifier.padding(horizontal = 40.dp).size(72.dp).background(Color.Black.copy(alpha = 0.35f), CircleShape), contentAlignment = Alignment.Center) {
        Icon(
            painterResource(if (side < 0) R.drawable.ic_replay_10 else R.drawable.ic_forward_10),
            if (side < 0) "Back 10 seconds" else "Forward 10 seconds", tint = Color.White, modifier = Modifier.size(36.dp),
        )
    }
}

/**
 * The video controls in the viewer's bottom panel, above the actions, the way Google Photos lays them out: a thin
 * scrubber across the width (what's loaded drawn lighter), then play or pause, the times, speed and sound.
 */
@kotlin.OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun VideoControls(session: VideoSession, modifier: Modifier = Modifier) {
    var scrubbing by remember { mutableStateOf<Float?>(null) }
    var menu by remember { mutableStateOf(false) }
    val shown = scrubbing ?: session.position
    val total = maxOf(session.duration, 0.1f)
    Column(modifier.fillMaxWidth().padding(horizontal = 8.dp)) {
        androidx.compose.animation.AnimatedVisibility(
            visible = scrubbing != null && session.strip.frames.isNotEmpty(),
            enter = androidx.compose.animation.fadeIn(androidx.compose.animation.core.tween(150)),
            exit = androidx.compose.animation.fadeOut(androidx.compose.animation.core.tween(150)),
        ) {
            FrameStripView(session.strip.frames, shown / total, Modifier.padding(horizontal = 16.dp).padding(bottom = 6.dp))
        }
        Slider(
            value = shown.coerceIn(0f, total), valueRange = 0f..total,
            onValueChange = { if (scrubbing == null) session.loadStrip(); scrubbing = it; session.scrub(it) },
            onValueChangeFinished = { scrubbing?.let(session::seekEnded); scrubbing = null },
            thumb = { Box(Modifier.size(if (scrubbing != null) 18.dp else 14.dp).background(Color.White, CircleShape)) },
            track = { state ->
                val range = state.valueRange.endInclusive - state.valueRange.start
                val played = if (range > 0) (state.value - state.valueRange.start) / range else 0f
                val loaded = (session.buffered / total).coerceIn(played, 1f)
                Canvas(Modifier.fillMaxWidth().height(4.dp)) {
                    val r = CornerRadius(size.height / 2)
                    drawRoundRect(Color.White.copy(alpha = 0.25f), cornerRadius = r)
                    drawRoundRect(Color.White.copy(alpha = 0.45f), size = Size(size.width * loaded, size.height), cornerRadius = r)
                    drawRoundRect(Color.White, size = Size(size.width * played, size.height), cornerRadius = r)
                }
            },
            modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp).height(32.dp).semantics {
                contentDescription = "Position"
                stateDescription = "${VideoLabels.time(shown.toDouble())} of ${VideoLabels.time(total.toDouble())}"
            },
        )
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            val pause = session.wantsPlay && !session.ended
            IconButton(onClick = session::togglePlay) {
                Icon(painterResource(if (pause) R.drawable.ic_pause else R.drawable.ic_play), if (pause) "Pause" else "Play", tint = Color.White)
            }
            Text(
                "${VideoLabels.time(shown.toDouble())} / ${VideoLabels.time(total.toDouble())}",
                color = Color.White, style = MaterialTheme.typography.labelLarge,
            )
            Spacer(Modifier.weight(1f))
            Box {
                TextButton(onClick = { menu = true }) {
                    Text(if (session.speed == 1f) "1×" else VideoLabels.speed(session.speed), color = Color.White, style = MaterialTheme.typography.labelLarge)
                }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    Text("Playback speed", style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
                    for (s in VideoLabels.speeds) DropdownMenuItem(
                        text = { Text(VideoLabels.speed(s)) },
                        trailingIcon = { if (s == session.speed) Icon(painterResource(R.drawable.ic_check), null) },
                        onClick = { menu = false; session.setRate(s) },
                    )
                }
            }
            IconButton(onClick = session::toggleMute) {
                Icon(painterResource(if (session.muted) R.drawable.ic_volume_off else R.drawable.ic_volume_up), if (session.muted) "Unmute" else "Mute", tint = Color.White)
            }
        }
    }
}

/**
 * The quality pill on a cloud video with a fast version, in the top bar: says what plays and switches to the other
 * version at any time (iOS `VideoQualityMenu`).
 */
@Composable
internal fun QualityPill(session: VideoSession) {
    var menu by remember { mutableStateOf(false) }
    val title = session.label(session.version) ?: if (session.version == VideoVersion.Original) "Original" else "Fast"
    Box {
        Row(
            Modifier.background(Color.White.copy(alpha = 0.18f), RoundedCornerShape(50))
                .pointerInput(Unit) { detectTapGestures { menu = true } }
                .padding(horizontal = 12.dp, vertical = 6.dp)
                .semantics {
                    contentDescription = "Video quality"
                    stateDescription = if (session.version == VideoVersion.Original) "Original" else "Fast version"
                },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            if (session.switching) CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(14.dp))
            Text(title, color = Color.White, style = MaterialTheme.typography.labelLarge)
            Icon(painterResource(R.drawable.ic_expand_more), null, tint = Color.White, modifier = Modifier.size(18.dp))
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            Text("Video quality", style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
            for (v in listOf(VideoVersion.Original, VideoVersion.Fast)) {
                val name = if (v == VideoVersion.Original) "Original quality" else "Fast version"
                // Offered only when this phone can play it; otherwise it would stutter or show broken colours.
                val usable = v == VideoVersion.Fast || session.originalPlayable
                DropdownMenuItem(
                    text = {
                        Column {
                            Text(session.label(v)?.let { "$name ($it)" } ?: name)
                            if (!usable) Text("This phone can't play it smoothly", style = MaterialTheme.typography.bodySmall)
                        }
                    },
                    enabled = usable,
                    trailingIcon = { if (session.version == v) Icon(painterResource(R.drawable.ic_check), null) },
                    onClick = { menu = false; session.choose(v) },
                )
            }
        }
    }
}
