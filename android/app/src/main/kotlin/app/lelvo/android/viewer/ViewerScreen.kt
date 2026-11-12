package app.lelvo.android.viewer

import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import android.text.format.DateFormat
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.expandHorizontally
import androidx.compose.animation.shrinkHorizontally
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import app.lelvo.android.LelvoApp
import app.lelvo.android.R
import app.lelvo.android.actions.DeleteDialog
import app.lelvo.android.actions.rememberPhoneActions
import app.lelvo.android.actions.shareEntries
import app.lelvo.android.shell.Messages
import app.lelvo.android.timeline.icon
import app.lelvo.android.timeline.tint
import app.lelvo.core.index.GalleryEntry
import app.lelvo.core.index.ItemKind
import app.lelvo.core.index.ItemStatus
import app.lelvo.core.index.PhoneAsset
import app.lelvo.core.support.AppLog
import app.lelvo.data.DemoMode
import app.lelvo.data.media.MediaException
import app.lelvo.data.media.SaveException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/**
 * Full-screen viewer, the way Google Photos shows one: black in both themes, tap to show or hide the bars, swipe
 * sideways between items, pinch or double tap to zoom, swipe up for details and down to close. The actions are the
 * iPhone's (iOS `ViewerView`): share, save to phone, favorite, details, delete.
 */
@Composable
fun ViewerScreen(items: List<GalleryEntry>, start: Int, onClose: () -> Unit) {
    BackHandler(onBack = onClose)
    val context = LocalContext.current
    val app = context.applicationContext as LelvoApp
    // Items removed here (moved to the phone's trash) leave at once; the grid catches up from MediaStore.
    val entries = remember { mutableStateListOf<GalleryEntry>().apply { addAll(items) } }
    val pager = rememberPagerState(initialPage = start.coerceIn(0, (items.size - 1).coerceAtLeast(0))) { entries.size }
    var chrome by rememberSaveable { mutableStateOf(true) }
    var zoomed by remember { mutableStateOf(false) }
    var info by rememberSaveable { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    // Favorites changed here show at once: the phone reports the change a moment later (iOS `favoriteOverrides`).
    val favorites = remember { mutableStateMapOf<String, Boolean>() }
    // The video on screen, for the quality pill in the top bar.
    var video by remember { mutableStateOf<Pair<String, VideoSession>?>(null) }
    val scope = rememberCoroutineScope()
    val haptics = LocalHapticFeedback.current
    // The bars follow the page once it lands, not halfway through a swipe: before, they switched to the next item while
    // the old one was still on screen and the buttons and video controls jumped.
    val current = entries.getOrNull(pager.settledPage)

    LaunchedEffect(entries.size) { if (entries.isEmpty()) onClose() }
    LaunchedEffect(pager.settledPage) { zoomed = false }

    val actions = rememberPhoneActions(
        onFavorited = { value -> current?.let { favorites[it.id] = value }; haptics.performHapticFeedback(HapticFeedbackType.Confirm) },
        onTrashed = { keepsPhone ->
            current?.let { entry ->
                // Deleted from the backup only: the photo is still on this phone, so its page stays, now phone-only.
                val i = entries.indexOf(entry)
                if (keepsPhone && entry.asset != null && i >= 0) entries[i] = entry.copy(item = null) else entries.remove(entry)
            }
        },
    )

    // The page on screen says when it's sharp; only then do the neighbours load.
    var readyId by remember { mutableStateOf<String?>(null) }
    // The photos either side load ahead on Wi-Fi once this one is sharp, so a swipe shows them sharp without slowing
    // the photo being looked at (iOS `prefetchPhoto` and `NeighbourPrefetcher`).
    LaunchedEffect(pager.settledPage, readyId) {
        if (readyId == null || readyId != entries.getOrNull(pager.settledPage)?.id) return@LaunchedEffect
        if (app.isMetered()) return@LaunchedEffect
        for (i in listOf(pager.settledPage + 1, pager.settledPage - 1)) {
            val e = entries.getOrNull(i) ?: continue
            // A photo on this phone opens from the phone; only cloud-only ones are fetched ahead.
            val n = e.item?.takeIf { e.asset == null } ?: continue
            if (n.kind != ItemKind.Video && DemoMode.assetUri(n) == null) app.media.prefetch(n)
        }
    }

    fun runTransfer(label: String, work: suspend () -> Unit) {
        if (busy) return
        busy = true
        scope.launch {
            try {
                Messages.runStoppable(work)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                AppLog.warn("Viewer: $label failed", e)
                val text = (e as? MediaException)?.message ?: (e as? SaveException)?.message ?: "Check your connection and try again."
                Messages.show(Messages.Style.Failure, if (label == "save") "Couldn't save" else "Couldn't share", text, seconds = 5.0)
            } finally {
                busy = false
            }
        }
    }

    fun share(entry: GalleryEntry, original: Boolean = false) = runTransfer("share") { shareEntries(context, listOf(entry), original) }

    fun save(entry: GalleryEntry) {
        val item = entry.item ?: return
        runTransfer("save") {
            Messages.progress("Saving original…", fraction = 0f)
            val id = app.saver.save(item) { Messages.update(it) }
            // The page is the phone's copy now: backed up, no second Save, and favorite and delete work on it.
            val i = entries.indexOfFirst { it.id == entry.id }
            if (i >= 0) entries[i] = entry.copy(
                asset = PhoneAsset(id, item.createdAt, isVideo = item.kind == ItemKind.Video, item.duration, item.width, item.height, filename = item.filename),
                item = item.copy(localId = id),
            )
            haptics.performHapticFeedback(HapticFeedbackType.Confirm)
            Messages.show(Messages.Style.Success, "Saved to this phone", "It's in Pictures › Lelvo.")
        }
    }

    Box(
        Modifier.fillMaxSize().background(Color.Black).verticalSwipes(
            enabled = { !zoomed },
            onUp = { info = true },
            onDown = onClose,
        ),
    ) {
        HorizontalPager(pager, key = { entries[it].id }, beyondViewportPageCount = 1, modifier = Modifier.fillMaxSize()) { page ->
            val entry = entries[page]
            ViewerPage(
                entry, current = pager.settledPage == page, chrome = chrome, onTap = { chrome = !chrome },
                onZoomed = { if (pager.settledPage == page) zoomed = it },
                onVideo = { session -> video = session?.let { entry.id to it } ?: video?.takeIf { it.first != entry.id } },
                onReady = { readyId = entry.id },
            )
        }
        AnimatedVisibility(chrome && current != null, enter = fadeIn(), exit = fadeOut(), modifier = Modifier.align(Alignment.TopCenter)) {
            val entry = current ?: return@AnimatedVisibility
            TopBar(
                entry, favorite = favorites[entry.id] ?: entry.isFavorite, onClose = onClose,
                onFavorite = { actions.favorite(listOf(entry), !(favorites[entry.id] ?: entry.isFavorite)) },
                onInfo = { info = true },
                onShareOriginal = if (canShareOriginal(entry)) ({ share(entry, original = true) }) else null,
                quality = video?.takeIf { it.first == entry.id && (it.second.hasFast || it.second.canMakeFast) }?.second,
            )
        }
        AnimatedVisibility(chrome && current != null, enter = fadeIn(), exit = fadeOut(), modifier = Modifier.align(Alignment.BottomCenter)) {
            val entry = current ?: return@AnimatedVisibility
            BottomBar(
                isVideo = entry.asset?.isVideo ?: (entry.item?.kind == ItemKind.Video),
                video = video?.takeIf { it.first == entry.id }?.second,
                canSave = canSave(entry), busy = busy,
                onShare = { share(entry) }, onSave = { save(entry) }, onInfo = { info = true }, onDelete = { confirmDelete = true },
            )
        }
    }
    if (info) current?.let { InfoSheet(it) { info = false } }
    if (confirmDelete) current?.let { entry ->
        DeleteDialog(listOf(entry), actions, onDismiss = { confirmDelete = false })
    }
}

/** Only in the cloud and readable from there: it can come back to this phone (iOS shows Save to Photos then). */
private fun canSave(entry: GalleryEntry): Boolean {
    val item = entry.item ?: return false
    return entry.asset == null && item.status == ItemStatus.BackedUp && DemoMode.assetUri(item) == null && !item.parts["o"].isNullOrEmpty()
}

/** An edited cloud photo can also go out as the untouched original (iOS "Share Original"). */
private fun canShareOriginal(entry: GalleryEntry): Boolean {
    val item = entry.item ?: return false
    return entry.asset == null && item.hasEdit && !item.parts["e"].isNullOrEmpty() && DemoMode.assetUri(item) == null
}

/** A tap that shows or hides the bars, without a ripple over the photo. */
internal fun Modifier.tapToToggle(onTap: () -> Unit): Modifier = clickable(interactionSource = null, indication = null, onClick = onTap)

/**
 * Google Photos' vertical swipes: up opens the details, down closes the viewer. Only once the finger has clearly moved
 * up or down, so sideways swipes still reach the pager, and never while a photo is zoomed in (then the swipe pans it).
 */
private fun Modifier.verticalSwipes(enabled: () -> Boolean, onUp: () -> Unit, onDown: () -> Unit): Modifier = pointerInput(Unit) {
    val threshold = 72.dp.toPx()
    var total = 0f
    var active = false
    detectVerticalDragGestures(
        onDragStart = { total = 0f; active = enabled() },
        onDragEnd = {
            if (active) when {
                total < -threshold -> onUp()
                total > threshold -> onDown()
            }
        },
        onDragCancel = { total = 0f },
    ) { change, dy ->
        if (!active) return@detectVerticalDragGestures
        change.consume()
        total += dy
    }
}

@Composable
private fun TopBar(
    entry: GalleryEntry, favorite: Boolean, onClose: () -> Unit, onFavorite: () -> Unit, onInfo: () -> Unit, onShareOriginal: (() -> Unit)?,
    quality: VideoSession?,
) {
    val locale = LocalContext.current.resources.configuration.locales[0]
    val day = remember(locale) { DateTimeFormatter.ofPattern(DateFormat.getBestDateTimePattern(locale, "dMMMyyyy"), locale) }
    val time = remember(locale) { DateTimeFormatter.ofPattern(DateFormat.getBestDateTimePattern(locale, "jmm"), locale) }
    var menu by remember { mutableStateOf(false) }
    // Room under the status bar and a long, soft fade, like Google Photos: the bar never sits on the picture's edge.
    Row(
        Modifier.fillMaxWidth()
            .background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.6f), Color.Black.copy(alpha = 0.25f), Color.Transparent)))
            .statusBarsPadding().padding(start = 4.dp, end = 4.dp, top = 8.dp, bottom = 40.dp)
            .heightIn(min = 56.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = onClose) { Icon(painterResource(R.drawable.ic_arrow_back), "Back", tint = Color.White) }
        Column(Modifier.weight(1f).padding(start = 4.dp)) {
            // In the time zone it was taken in, when the backup knows it, like the details and Google Photos.
            val zone = entry.item?.tzOffsetMinutes?.let { java.time.ZoneOffset.ofTotalSeconds(it * 60) } ?: ZoneId.systemDefault()
            val at = entry.date?.let { Instant.ofEpochMilli(it).atZone(zone) }
            Text(at?.let(day::format) ?: "Unknown date", color = Color.White, style = MaterialTheme.typography.titleMedium)
            Row(verticalAlignment = Alignment.CenterVertically) {
                at?.let { Text(time.format(it), color = Color.White.copy(alpha = 0.8f), style = MaterialTheme.typography.bodySmall) }
                Spacer(Modifier.width(6.dp))
                // Where it is, in the iPhone's words: on the phone and in the cloud, only on this phone, and so on.
                Icon(painterResource(entry.badge.icon), entry.badge.label, Modifier.size(14.dp), tint = entry.badge.tint())
            }
        }
        quality?.let { if (it.hasFast) QualityPill(it) else MakeFastPill(it) }
        IconButton(onClick = onFavorite) {
            Icon(
                painterResource(if (favorite) R.drawable.ic_favorite else R.drawable.ic_favorite_border),
                if (favorite) "Remove from favorites" else "Add to favorites", tint = Color.White,
            )
        }
        Box {
            IconButton(onClick = { menu = true }) { Icon(painterResource(R.drawable.ic_more_vert), "More options", tint = Color.White) }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                DropdownMenuItem(text = { Text("Details") }, onClick = { menu = false; onInfo() })
                onShareOriginal?.let { DropdownMenuItem(text = { Text("Share original") }, onClick = { menu = false; it() }) }
            }
        }
    }
}

/**
 * The bottom panel: a video's controls (when one plays) above the actions, on one fade, so both stay readable over a
 * bright picture.
 */
@Composable
private fun BottomBar(
    isVideo: Boolean, video: VideoSession?, canSave: Boolean, busy: Boolean,
    onShare: () -> Unit, onSave: () -> Unit, onInfo: () -> Unit, onDelete: () -> Unit,
) {
    // A video's player starts a frame or two after its page lands; its controls' room is kept meanwhile, so the bar
    // doesn't drop and rise again between two videos.
    var controlsHeight by remember { mutableIntStateOf(0) }
    val density = LocalDensity.current
    Column(
        Modifier.fillMaxWidth()
            .background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.35f), Color.Black.copy(alpha = 0.7f))))
            .navigationBarsPadding().padding(top = if (isVideo) 48.dp else 40.dp, bottom = 8.dp)
            .animateContentSize(),
    ) {
        when {
            video != null -> VideoControls(video, Modifier.padding(bottom = 4.dp).onSizeChanged { controlsHeight = it.height })
            isVideo && controlsHeight > 0 -> Spacer(Modifier.height(with(density) { controlsHeight.toDp() }))
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
            BarAction(R.drawable.ic_send, "Share", enabled = !busy, onShare)
            // Slides in and out between a cloud item and a phone one, rather than the other buttons jumping sideways.
            AnimatedVisibility(canSave, enter = fadeIn() + expandHorizontally(), exit = fadeOut() + shrinkHorizontally()) {
                BarAction(R.drawable.ic_download, "Save", enabled = !busy, onSave)
            }
            BarAction(R.drawable.ic_info_outline, "Details", enabled = true, onInfo)
            BarAction(R.drawable.ic_delete, "Delete", enabled = true, onDelete)
        }
    }
}

@Composable
private fun BarAction(icon: Int, label: String, enabled: Boolean, onClick: () -> Unit) {
    TextButton(onClick = onClick, enabled = enabled, modifier = Modifier.widthIn(min = 72.dp)) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
            val color = if (enabled) Color.White else Color.White.copy(alpha = 0.4f)
            Icon(painterResource(icon), null, tint = color)
            Text(label, style = MaterialTheme.typography.labelMedium, color = color)
        }
    }
}
