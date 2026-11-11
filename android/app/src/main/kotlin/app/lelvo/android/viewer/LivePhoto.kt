package app.lelvo.android.viewer

import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.annotation.OptIn
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.foundation.clickable
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import app.lelvo.android.LelvoApp
import app.lelvo.android.R
import app.lelvo.android.media.CloudDataSource
import app.lelvo.android.media.VideoDecoders
import app.lelvo.android.shell.Messages
import app.lelvo.core.index.LibraryItem
import app.lelvo.core.support.AppLog

/**
 * A Live Photo from the cloud: the photo, zoomable like any other, and its motion on request: the LIVE chip or a
 * long press plays it once with sound, over the photo (iOS `LivePhotoView`: touch and hold, or the LIVE button).
 * Nothing plays on its own, so swiping through Live Photos never downloads their videos.
 */
@OptIn(UnstableApi::class)
@Composable
internal fun LivePhotoPage(item: LibraryItem, current: Boolean, chrome: Boolean, onTap: () -> Unit, onZoomed: (Boolean) -> Unit, onReady: () -> Unit) {
    val context = LocalContext.current
    val app = context.applicationContext as LelvoApp
    WithMotion(
        key = item.id, label = "LIVE", name = "Live Photo", current = current, chrome = chrome,
        source = {
            // The edited Live Photo's motion goes with the edited still the viewer shows.
            val role = if (app.media.displayedRole(item) == "e" && !item.parts["epv"].isNullOrEmpty()) "epv" else "pv"
            ProgressiveMediaSource.Factory(CloudDataSource.Factory(app.reader, item, role))
                .createMediaSource(MediaItem.fromUri("lelvo://item/${item.id}/$role"))
        },
    ) { onLongPress ->
        CloudPhotoPage(item, current, onTap, onZoomed, onLongPress = onLongPress, onReady = { if (current) onReady() })
    }
}

/**
 * A photo with motion to play over it: a cloud Live Photo, or an Android Motion Photo (the video is inside the
 * file). [source] builds the player's input; [photo] draws the still and hands its long press on. Plays once with
 * sound on the chip or a long press, never on its own. A null [source] (not known yet, or none) shows the photo alone,
 * in the same place in the layout, so the photo isn't loaded again when the motion turns up.
 */
@OptIn(UnstableApi::class)
@Composable
internal fun WithMotion(
    key: String, label: String, name: String, current: Boolean, chrome: Boolean,
    failHint: String = "Check your connection and try again.",
    source: (() -> androidx.media3.exoplayer.source.MediaSource)?,
    photo: @Composable (onLongPress: (() -> Unit)?) -> Unit,
) {
    var playing by remember(key) { mutableStateOf(false) }
    var moving by remember(key) { mutableStateOf(false) }
    LaunchedEffect(current) { if (!current) playing = false }
    LaunchedEffect(playing) { if (!playing) moving = false }
    Box(Modifier.fillMaxSize()) {
        // The motion sits behind the photo; the photo steps aside once the motion has a picture.
        if (playing && source != null) LiveMotion(key, name, failHint, source, onShown = { moving = true }, onDone = { playing = false })
        // Solid black, not just the photo: around a photo the page is see-through, and the motion's first frames
        // showed there before the photo stepped aside.
        Box(Modifier.fillMaxSize().alpha(if (moving) 0f else 1f).background(Color.Black)) {
            photo(if (source != null) ({ playing = true }) else null)
        }
        if (chrome && current && source != null) {
            Row(
                Modifier.statusBarsPadding().padding(start = 16.dp, top = 76.dp)
                    .background(Color.Black.copy(alpha = 0.4f), RoundedCornerShape(12.dp))
                    .clickable(onClick = { playing = !playing })
                    .semantics {
                        role = Role.Button
                        contentDescription = if (playing) "Stop $name" else "Play $name"
                    }
                    .padding(horizontal = 8.dp, vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(painterResource(R.drawable.ic_motion_photos), null, tint = Color.White, modifier = Modifier.size(16.dp))
                Text(label, color = Color.White, style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(start = 4.dp))
            }
        }
    }
}

/** The paired video, played once. [onShown] comes with its first frame, so nothing flashes black. */
@OptIn(UnstableApi::class)
@Composable
private fun LiveMotion(key: String, name: String, failHint: String, source: () -> androidx.media3.exoplayer.source.MediaSource, onShown: () -> Unit, onDone: () -> Unit) {
    val context = LocalContext.current
    val done by rememberUpdatedState(onDone)
    val firstFrame by rememberUpdatedState(onShown)
    val player = remember(key) {
        val opened = System.currentTimeMillis()
        ExoPlayer.Builder(context, VideoDecoders.renderers(context))
            .setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(), true)
            .build().apply {
                setMediaSource(source())
                addListener(object : Player.Listener {
                    override fun onRenderedFirstFrame() {
                        AppLog.info("$name timing: motion after ${System.currentTimeMillis() - opened} ms")
                        firstFrame()
                    }

                    override fun onPlaybackStateChanged(state: Int) { if (state == Player.STATE_ENDED) done() }

                    override fun onPlayerError(e: PlaybackException) {
                        AppLog.warn("$name: motion didn't play: ${e.errorCodeName}")
                        Messages.show(Messages.Style.Failure, "Couldn't play the $name", failHint)
                        done()
                    }
                })
                prepare()
                playWhenReady = true
            }
    }
    DisposableEffect(player) { onDispose { player.release() } }
    AndroidView(
        factory = {
            (android.view.LayoutInflater.from(it).inflate(R.layout.video_surface, null) as PlayerView).apply { this.player = player }
        },
        modifier = Modifier.fillMaxSize(),
    )
}
