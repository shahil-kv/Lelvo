package app.lelvo.android.viewer

import app.lelvo.core.support.AppLog
import app.lelvo.data.Prefs
import app.lelvo.core.video.VideoVersion
import app.lelvo.core.video.VideoQualityPolicy
import app.lelvo.core.video.VideoPreference
import app.lelvo.core.video.VideoNavigation
import app.lelvo.android.media.CloudDataSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.common.util.UnstableApi
import androidx.media3.common.Player
import androidx.media3.common.PlaybackException
import androidx.compose.ui.unit.dp
import androidx.compose.material3.MaterialTheme
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.LaunchedEffect
import app.lelvo.data.media.MediaException
import app.lelvo.android.media.CloudThumbnail
import app.lelvo.android.media.CloudPhoto
import app.lelvo.android.LelvoApp
import android.text.format.DateFormat
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.MediaItem
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import app.lelvo.android.R
import app.lelvo.core.index.ItemKind
import app.lelvo.core.index.LibraryItem
import app.lelvo.data.DemoMode
import coil3.compose.AsyncImage
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/** Full-screen viewer: swipe between items, tap to show or hide the bar. Zoom and the info sheet are Step 9. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ViewerScreen(items: List<LibraryItem>, start: Int, onClose: () -> Unit) {
    BackHandler(onBack = onClose)
    val pager = rememberPagerState(initialPage = start.coerceIn(0, (items.size - 1).coerceAtLeast(0))) { items.size }
    var chrome by rememberSaveable { mutableStateOf(true) }
    val locale = LocalContext.current.resources.configuration.locales[0]
    val formatter = remember(locale) { DateTimeFormatter.ofPattern(DateFormat.getBestDateTimePattern(locale, "EEEdMMMyyyyjmm"), locale) }

    val app = LocalContext.current.applicationContext as LelvoApp
    // The photos either side load ahead on Wi-Fi, so a swipe shows them sharp (iOS `prefetchPhoto`).
    LaunchedEffect(pager.settledPage) {
        if (app.isMetered()) return@LaunchedEffect
        for (i in listOf(pager.settledPage + 1, pager.settledPage - 1)) {
            val n = items.getOrNull(i) ?: continue
            if (n.kind != ItemKind.Video && DemoMode.assetUri(n) == null) app.media.prefetch(n)
        }
    }
    Box(Modifier.fillMaxSize().background(Color.Black)) {
        HorizontalPager(pager, key = { items[it].id }, beyondViewportPageCount = 1, modifier = Modifier.fillMaxSize()) { page ->
            val item = items[page]
            val toggle = Modifier.clickable(remember { MutableInteractionSource() }, indication = null) { chrome = !chrome }
            if (item.kind == ItemKind.Video) {
                // Only the page on screen plays; the neighbours show their first frame.
                if (pager.settledPage == page) VideoPage(item) else Poster(item, toggle)
            } else {
                Poster(item, toggle)
            }
        }
        if (chrome) {
            val item = items.getOrNull(pager.currentPage)
            TopAppBar(
                title = {
                    Column {
                        Text(item?.createdAt?.let { formatter.format(Instant.ofEpochMilli(it).atZone(ZoneId.systemDefault())) } ?: "Unknown date")
                    }
                },
                navigationIcon = {
                    IconButton(onClick = onClose) { Icon(painterResource(R.drawable.ic_arrow_back), contentDescription = "Back") }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = Color.Black.copy(alpha = 0.4f), titleContentColor = Color.White, navigationIconContentColor = Color.White,
                ),
            )
        }
    }
}

@Composable
private fun Poster(item: LibraryItem, modifier: Modifier) {
    val demo = DemoMode.assetUri(item)
    val description = if (item.kind == ItemKind.Video) "Video" else "Photo"
    if (demo != null || item.kind == ItemKind.Video) {
        AsyncImage(
            model = demo ?: CloudThumbnail(item), contentDescription = description, contentScale = ContentScale.Fit,
            modifier = Modifier.fillMaxSize().then(modifier),
        )
        return
    }
    CloudPhotoPage(item, description, modifier)
}

/**
 * A cloud photo the way iOS shows one: the thumbnail at once, the screen copy of a big photo next (a few hundred KB),
 * then the photo itself on top. Each layer stays until the one above has drawn, so nothing flashes.
 */
@Composable
private fun CloudPhotoPage(item: LibraryItem, description: String, modifier: Modifier) {
    val media = (LocalContext.current.applicationContext as LelvoApp).media
    var sharp by remember(item.id) { mutableStateOf(false) }
    var error by remember(item.id) { mutableStateOf<String?>(null) }
    val useCopy = remember(item.id) { media.hasScreenCopy(item) && media.cachedDisplayed(item) == null }
    Box(Modifier.fillMaxSize().then(modifier)) {
        if (!sharp) {
            AsyncImage(CloudThumbnail(item), null, contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize())
            if (useCopy) AsyncImage(CloudPhoto(item, screenCopy = true), null, contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize())
        }
        AsyncImage(
            CloudPhoto(item), description, contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize(),
            onSuccess = { sharp = true },
            onError = { error = (it.result.throwable as? MediaException)?.message ?: "Couldn't load this photo. Check your connection and try again." },
        )
        error?.let {
            Text(
                it, color = Color.White, style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.align(Alignment.BottomCenter).padding(24.dp).background(Color.Black.copy(alpha = 0.6f), RoundedCornerShape(12.dp)).padding(12.dp),
            )
        }
    }
}

/**
 * A video plays straight from Telegram: the fast version when the setting allows and there is one, else the original
 * (or its edit). Long videos start where they were left.
 */
@androidx.annotation.OptIn(UnstableApi::class)
@Composable
private fun VideoPage(item: LibraryItem) {
    val context = LocalContext.current
    val app = context.applicationContext as LelvoApp
    val demo = DemoMode.assetUri(item)
    var error by remember(item.id) { mutableStateOf<String?>(null) }
    val player = remember(item.id) {
        val opened = System.currentTimeMillis()
        var playing = "demo"
        ExoPlayer.Builder(context).build().apply {
            if (demo != null) {
                setMediaItem(MediaItem.fromUri(demo))
            } else {
                val preference = when (app.prefs.videoQuality) {
                    Prefs.VideoQuality.Original -> VideoPreference.Original
                    Prefs.VideoQuality.Fast -> VideoPreference.Fast
                    Prefs.VideoQuality.Automatic -> VideoPreference.Automatic
                }
                val role = when (VideoQualityPolicy.initial(preference, hasFast = !item.parts["sp"].isNullOrEmpty())) {
                    VideoVersion.Fast -> "sp"
                    VideoVersion.Original -> app.media.displayedRole(item)
                }
                playing = if (role == "sp") "fast version" else "original"
                val source = ProgressiveMediaSource.Factory(CloudDataSource.Factory(app.reader, item, role))
                    .createMediaSource(MediaItem.fromUri("lelvo://item/${item.id}/$role"))
                setMediaSource(source)
                VideoNavigation.resumePosition(app.positions.position(item.id), item.duration ?: 0.0)?.let { seekTo((it * 1000).toLong()) }
            }
            addListener(object : Player.Listener {
                override fun onRenderedFirstFrame() {
                    AppLog.info("Video timing: $playing, first frame after ${System.currentTimeMillis() - opened} ms")
                }

                override fun onPlayerError(e: PlaybackException) {
                    error = (generateSequence<Throwable>(e) { it.cause }.firstOrNull { it is MediaException } as? MediaException)?.message
                        ?: "This video can't play right now. Check your connection and try again."
                }
            })
            prepare()
            playWhenReady = true
        }
    }
    // The sound stops when the page or the viewer goes away (iOS #115), and a long video remembers where it was left.
    DisposableEffect(player) {
        onDispose {
            val duration = if (player.duration > 0) player.duration / 1000.0 else item.duration ?: 0.0
            if (demo == null) app.positions.record(item.id, player.currentPosition / 1000.0, duration)
            player.release()
        }
    }
    Box(Modifier.fillMaxSize()) {
        AndroidView(
            factory = { PlayerView(it).apply { this.player = player; setShowNextButton(false); setShowPreviousButton(false) } },
            modifier = Modifier.fillMaxSize(),
        )
        error?.let {
            Text(
                it, color = Color.White, style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.align(Alignment.Center).padding(24.dp).background(Color.Black.copy(alpha = 0.6f), RoundedCornerShape(12.dp)).padding(12.dp),
            )
        }
    }
}
