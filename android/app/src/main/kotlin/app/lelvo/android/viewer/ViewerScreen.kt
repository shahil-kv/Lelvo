package app.lelvo.android.viewer

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
    AsyncImage(
        model = DemoMode.assetUri(item),
        contentDescription = if (item.kind == ItemKind.Video) "Video" else "Photo",
        contentScale = ContentScale.Fit,
        modifier = Modifier.fillMaxSize().then(modifier),
    )
}

@Composable
private fun VideoPage(item: LibraryItem) {
    val context = LocalContext.current
    val uri = DemoMode.assetUri(item)
    if (uri == null) {
        // Streaming from Telegram is Step 10.
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text("This video can't play yet.", color = Color.White)
        }
        return
    }
    val player = remember(item.id) {
        ExoPlayer.Builder(context).build().apply {
            setMediaItem(MediaItem.fromUri(uri))
            prepare()
            playWhenReady = true
        }
    }
    // The sound stops when the page or the viewer goes away (iOS #115).
    DisposableEffect(player) { onDispose { player.release() } }
    AndroidView(
        factory = { PlayerView(it).apply { this.player = player; setShowNextButton(false); setShowPreviousButton(false) } },
        modifier = Modifier.fillMaxSize(),
    )
}
