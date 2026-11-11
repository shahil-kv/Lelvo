package app.lelvo.android.viewer

import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import app.lelvo.android.LelvoApp
import app.lelvo.android.media.CloudPhoto
import app.lelvo.android.media.CloudThumbnail
import app.lelvo.android.media.PhoneThumbnail
import app.lelvo.core.index.GalleryEntry
import app.lelvo.core.index.ItemKind
import app.lelvo.core.index.LibraryItem
import app.lelvo.core.support.AppLog
import app.lelvo.data.DemoMode
import app.lelvo.data.media.MediaException
import coil3.compose.AsyncImage
import kotlinx.coroutines.CancellationException
import me.saket.telephoto.zoomable.coil3.ZoomableAsyncImage
import me.saket.telephoto.zoomable.rememberZoomableImageState
import me.saket.telephoto.zoomable.rememberZoomableState

/**
 * One page of the viewer: a zoomable photo, or a video, from the phone or from Telegram. [current] is the page on
 * screen (only it plays). [onZoomed] reports whether the photo is zoomed in, so a vertical swipe pans it instead of
 * opening the details or closing the viewer. [onVideo] hands the playing video to the top bar's quality pill.
 */
@Composable
internal fun ViewerPage(
    entry: GalleryEntry, current: Boolean, chrome: Boolean, onTap: () -> Unit, onZoomed: (Boolean) -> Unit, onVideo: (VideoSession?) -> Unit,
    onReady: () -> Unit,
) {
    val app = LocalContext.current.applicationContext as LelvoApp
    val cloudPhoto = entry.asset == null && entry.item?.kind != ItemKind.Video && entry.item?.let(DemoMode::assetUri) == null
    // Anything but a cloud photo is ready at once (phone files are local; a video buffers on its own).
    if (current && !cloudPhoto) LaunchedEffect(entry.id) { onReady() }
    val asset = entry.asset
    val item = entry.item
    when {
        // On this phone: shown and played from the phone, whatever the backup holds. Only the page on screen plays;
        // the neighbours show their first frame.
        asset != null && asset.isVideo -> {
            val uri = app.photos.uri(asset)
            if (current) VideoPage(entry.id, uri, null, PhoneThumbnail(uri), chrome, onTap, onVideo) else Still(PhoneThumbnail(uri), "Video", onTap)
        }
        asset != null -> PhonePhotoPage(asset.localId, app.photos.uri(asset), current, chrome, onTap, onZoomed)
        item == null -> Unit
        item.kind == ItemKind.Video -> {
            val poster = DemoMode.assetUri(item) ?: CloudThumbnail(item)
            if (current) VideoPage(entry.id, null, item, poster, chrome, onTap, onVideo) else Still(poster, "Video", onTap)
        }
        item.kind == ItemKind.LivePhoto && DemoMode.assetUri(item) == null && !item.parts["pv"].isNullOrEmpty() ->
            LivePhotoPage(item, current, chrome, onTap, onZoomed, onReady)
        else -> DemoMode.assetUri(item)?.let { ZoomablePhoto(it, current, onTap, onZoomed) }
            ?: CloudMotionPhotoPage(item, current, chrome, onTap, onZoomed, onReady = { if (current) onReady() })
    }
}

/**
 * A photo on this phone. An Android Motion Photo (the video is inside the file) gets the MOTION chip and plays on a
 * long press, like a Live Photo. Only the page on screen is checked: it reads the file's first 256 KB.
 */
@Composable
private fun PhonePhotoPage(localId: String, uri: Uri, current: Boolean, chrome: Boolean, onTap: () -> Unit, onZoomed: (Boolean) -> Unit) {
    val app = LocalContext.current.applicationContext as LelvoApp
    var motion by remember(localId) { mutableStateOf<java.io.File?>(null) }
    LaunchedEffect(localId, current) { if (current && motion == null) motion = app.motion.video(uri, "p_$localId") }
    MotionPhotoPage("p_$localId", motion, current, chrome, failHint = "Try again.") { onLongPress ->
        ZoomablePhoto(uri, current, onTap, onZoomed, onLongPress = onLongPress)
    }
}

/** A backed-up photo: an Android Motion Photo is uploaded as one file (kind `p`), so its motion is found in the original. */
@Composable
private fun CloudMotionPhotoPage(item: LibraryItem, current: Boolean, chrome: Boolean, onTap: () -> Unit, onZoomed: (Boolean) -> Unit, onReady: () -> Unit) {
    val app = LocalContext.current.applicationContext as LelvoApp
    var original by remember(item.id) { mutableStateOf<java.io.File?>(null) }
    var motion by remember(item.id) { mutableStateOf<java.io.File?>(null) }
    LaunchedEffect(original, current) {
        val f = original ?: return@LaunchedEffect
        if (current && motion == null) motion = app.motion.video(Uri.fromFile(f), "c_${item.id}_${app.media.displayedRole(item)}")
    }
    MotionPhotoPage("c_${item.id}", motion, current, chrome) { onLongPress ->
        CloudPhotoPage(item, current, onTap, onZoomed, onLongPress = onLongPress, onReady = onReady, onFile = { original = it })
    }
}

@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
@Composable
private fun MotionPhotoPage(
    key: String, motion: java.io.File?, current: Boolean, chrome: Boolean, failHint: String = "Check your connection and try again.",
    photo: @Composable (onLongPress: (() -> Unit)?) -> Unit,
) {
    val context = LocalContext.current
    WithMotion(
        key = key, label = "MOTION", name = "Motion Photo", current = current, chrome = chrome, failHint = failHint,
        source = motion?.let { f ->
            {
                androidx.media3.exoplayer.source.ProgressiveMediaSource.Factory(androidx.media3.datasource.DefaultDataSource.Factory(context))
                    .createMediaSource(androidx.media3.common.MediaItem.fromUri(Uri.fromFile(f)))
            }
        },
        photo = photo,
    )
}

@Composable
private fun Still(model: Any, description: String, onTap: () -> Unit) {
    AsyncImage(model, description, contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize().tapToToggle(onTap))
}

/**
 * Pinch and double tap to zoom, like Photos (iOS `ZoomableImageView`), up to twice the photo's own pixels. Telephoto reads big photos in tiles
 * from the file once zoomed in, so a 48 MP photo is sharp without holding all of it in memory (iOS loads the full
 * detail on zoom for the same reason). Swiping to the next photo resets the zoom.
 */
@Composable
private fun ZoomablePhoto(
    model: Any, current: Boolean, onTap: () -> Unit, onZoomed: (Boolean) -> Unit, onLoaded: () -> Unit = {}, onLongPress: (() -> Unit)? = null,
) {
    val state = rememberZoomableImageState(rememberZoomableState())
    val zoomed by rememberUpdatedState(onZoomed)
    val loaded by rememberUpdatedState(onLoaded)
    LaunchedEffect(state, current) {
        if (!current) { state.zoomableState.resetZoom(); return@LaunchedEffect }
        snapshotFlow { (state.zoomableState.zoomFraction ?: 0f) > 0.01f }.collect { zoomed(it) }
    }
    LaunchedEffect(state) { snapshotFlow { state.isImageDisplayed }.collect { if (it) loaded() } }
    ZoomableAsyncImage(
        model = model, contentDescription = "Photo", state = state, modifier = Modifier.fillMaxSize(),
        onClick = { onTap() },
        onLongClick = onLongPress?.let { f -> { _: androidx.compose.ui.geometry.Offset -> f() } },
    )
}

/**
 * A cloud photo the way iOS shows one: the thumbnail at once, the screen copy of a big photo next (a few hundred KB),
 * then the photo itself, zoomable, on top. Each layer stays until the one above has drawn, so nothing flashes.
 */
@Composable
internal fun CloudPhotoPage(
    item: LibraryItem, current: Boolean, onTap: () -> Unit, onZoomed: (Boolean) -> Unit, onLongPress: (() -> Unit)? = null, onReady: () -> Unit = {},
    onFile: (java.io.File) -> Unit = {},
) {
    val media = (LocalContext.current.applicationContext as LelvoApp).media
    var file by remember(item.id) { mutableStateOf(media.cachedDisplayed(item)) }
    var sharp by remember(item.id) { mutableStateOf(false) }
    var error by remember(item.id) { mutableStateOf<String?>(null) }
    val useCopy = remember(item.id) { media.hasScreenCopy(item) && file == null }
    // The pager also builds the pages either side. Only the page on screen downloads: neighbours fetched at the same
    // time split the connection six ways, and the photo being looked at came last. The viewer fetches them ahead
    // once this one is sharp (iOS `NeighbourPrefetcher`).
    var wanted by remember(item.id) { mutableStateOf(false) }
    if (current) wanted = true
    LaunchedEffect(item.id, wanted) {
        if (file != null || !wanted) return@LaunchedEffect
        try {
            // The screen copy first (a few hundred KB, on screen in about a second), then the photo.
            if (useCopy) runCatching { media.screenCopy(item) }
            file = media.displayed(item)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            AppLog.warn("Viewer: photo didn't load", e)
            error = (e as? MediaException)?.message ?: "Couldn't load this photo. Check your connection and try again."
        }
    }
    val gotFile by rememberUpdatedState(onFile)
    LaunchedEffect(file) { file?.let(gotFile) }
    val ready by rememberUpdatedState(onReady)
    LaunchedEffect(sharp, error) { if (sharp || error != null) ready() }
    // How long the photo on screen took to turn sharp, and a warning if a downloaded one doesn't: HEIC photos once
    // never did, and nothing in the log said so (iOS `logPhotoTiming`).
    val opened = remember(item.id) { System.currentTimeMillis() }
    val wasCached = remember(item.id) { file != null }
    LaunchedEffect(sharp) {
        if (sharp && current) AppLog.info("Photo timing: sharp after ${System.currentTimeMillis() - opened} ms${if (wasCached) " (already on this phone)" else ""}")
    }
    LaunchedEffect(file, sharp, current) {
        val f = file ?: return@LaunchedEffect
        if (sharp || !current) return@LaunchedEffect
        kotlinx.coroutines.delay(5_000)
        AppLog.warn("Photo: a ${f.extension} of ${f.length() shr 10} KB isn't sharp 5 s after it downloaded")
    }
    Box(Modifier.fillMaxSize()) {
        if (!sharp) {
            Box(Modifier.fillMaxSize().tapToToggle(onTap)) {
                AsyncImage(CloudThumbnail(item), null, contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize())
                if (useCopy && wanted) AsyncImage(CloudPhoto(item, screenCopy = true), null, contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize())
            }
        }
        file?.let { ZoomablePhoto(Uri.fromFile(it), current, onTap, onZoomed, onLoaded = { sharp = true }, onLongPress = onLongPress) }
        if (file == null && error == null && current) {
            CircularProgressIndicator(
                color = Color.White, strokeWidth = 2.dp,
                modifier = Modifier.align(Alignment.Center).background(Color.Black.copy(alpha = 0.35f), RoundedCornerShape(50)).padding(12.dp),
            )
        }
        error?.let { ViewerNotice(it, Modifier.align(Alignment.BottomCenter).padding(bottom = 140.dp)) }
    }
}

@Composable
internal fun ViewerNotice(text: String, modifier: Modifier = Modifier) {
    Text(
        text, color = Color.White, style = MaterialTheme.typography.bodyMedium,
        modifier = modifier.padding(24.dp).background(Color.Black.copy(alpha = 0.6f), RoundedCornerShape(12.dp)).padding(12.dp),
    )
}
