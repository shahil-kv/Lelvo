package app.lelvo.android.timeline

import app.lelvo.android.ui.theme.Lelvo
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.draw.clip
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.combine
import app.lelvo.data.media.PhotoAccess
import app.lelvo.core.index.GalleryFilter
import app.lelvo.core.index.GalleryEntry
import app.lelvo.core.index.Gallery
import app.lelvo.android.media.PhoneThumbnail
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.material3.InputChip
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.Spacer
import android.text.format.DateFormat
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.lelvo.android.R
import app.lelvo.android.shell.LelvoTopBar
import app.lelvo.android.shell.Messages
import app.lelvo.core.index.ItemKind
import app.lelvo.core.index.LibraryItem
import app.lelvo.core.index.Timeline
import app.lelvo.data.DemoMode
import app.lelvo.data.Prefs
import app.lelvo.data.index.LibraryStore
import app.lelvo.android.media.CloudThumbnail
import coil3.compose.AsyncImage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/** Pinch steps: columns and how sections are split, like Photos' day, month and year views. */
private val zoomLevels = listOf(2 to Timeline.Grouping.Day, 3 to Timeline.Grouping.Day, 5 to Timeline.Grouping.Month, 8 to Timeline.Grouping.Year)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TimelineScreen(
    store: LibraryStore, photos: PhotoAccess, demo: DemoMode, prefs: Prefs, onOpen: (List<GalleryEntry>, Int) -> Unit, onSettings: () -> Unit,
    modifier: Modifier = Modifier,
    /** An album, folder, day or media type from Collections: the grid shows only it, with Back instead of the menu. */
    collection: GalleryFilter? = null,
    onBack: () -> Unit = {},
) {
    var level by rememberSaveable {
        mutableIntStateOf(zoomLevels.indexOfFirst { it.first == prefs.gridColumns }.takeIf { it >= 0 } ?: 1)
    }
    val (columns, grouping) = zoomLevels[level]
    // Sorting and grouping run off the main thread; the grid only lays out the result.
    val isDemo by demo.active.collectAsState()
    var filter by rememberSaveable { mutableStateOf(collection) }
    var legend by remember { mutableStateOf(false) }
    var selection by remember { mutableStateOf(emptySet<String>()) }
    val selecting = selection.isNotEmpty()
    androidx.activity.compose.BackHandler(enabled = selecting) { selection = emptySet() }
    // Phone photos and cloud items in one timeline (iOS `GalleryModel.merge`); merging, filtering and grouping run off
    // the main thread, and a change to either side redraws only what moved.
    val sections by produceState<List<Timeline.Section<GalleryEntry>>?>(null, store, grouping, filter, isDemo) {
        galleryEntries(store, photos, isDemo)
            .map { all -> Timeline.groupEntries(filter?.let { f -> all.filter(f::matches) } ?: all, grouping, ZoneId.systemDefault(), LocalDate.now()) }
            .flowOn(Dispatchers.Default)
            .collect { value = it }
    }
    val backup by demo.backup.collectAsState()
    val scope = rememberCoroutineScope()
    var menu by remember { mutableStateOf(false) }
    val scrollBehavior = TopAppBarDefaults.enterAlwaysScrollBehavior()

    LaunchedEffect(backup?.running) {
        val b = backup ?: return@LaunchedEffect
        if (!b.running) Messages.show(Messages.Style.Success, if (b.total == 0) "Everything is backed up" else "Backed up ${b.done} item${if (b.done == 1) "" else "s"}")
    }

    Scaffold(
        modifier = modifier.nestedScroll(scrollBehavior.nestedScrollConnection),
        topBar = {
            if (selecting) TopAppBar(
                navigationIcon = { IconButton(onClick = { selection = emptySet() }) { Icon(painterResource(R.drawable.ic_close), "Clear selection") } },
                title = { Text("${selection.size} selected") },
                actions = {
                    TextButton(onClick = { selection = sections.orEmpty().flatMap { s -> s.items.map { it.id } }.toSet() }) { Text("Select all") }
                },
            ) else if (collection != null) TopAppBar(
                navigationIcon = { IconButton(onClick = onBack) { Icon(painterResource(R.drawable.ic_arrow_back), "Back") } },
                title = { Text(collection.title, maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis) },
                scrollBehavior = scrollBehavior,
                actions = {
                    IconButton(onClick = { menu = true }) { Icon(painterResource(R.drawable.ic_more_vert), contentDescription = "More options") }
                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        DropdownMenuItem(text = { Text("What the icons mean") }, onClick = { menu = false; legend = true })
                    }
                },
            ) else Column {
                LelvoTopBar(filter?.title ?: "Photos", demo, onSettings, scrollBehavior) {
                    IconButton(onClick = { menu = true }) {
                        Icon(painterResource(R.drawable.ic_more_vert), contentDescription = "More options")
                    }
                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        // Real backup is Phase I; until then only the demo simulates one.
                        if (isDemo) DropdownMenuItem(
                            text = { Text("Back up now") },
                            enabled = backup?.running != true,
                            onClick = { menu = false; scope.launch { demo.runBackup() } },
                        )
                        DropdownMenuItem(
                            text = { Text("All photos") },
                            trailingIcon = { if (filter == null) Icon(painterResource(R.drawable.ic_check_circle), null) },
                            onClick = { menu = false; filter = null },
                        )
                        for (f in GalleryFilter.entries) DropdownMenuItem(
                            text = { Text(f.title) },
                            trailingIcon = { if (filter == f) Icon(painterResource(R.drawable.ic_check_circle), null) },
                            onClick = { menu = false; filter = f },
                        )
                        DropdownMenuItem(text = { Text("What the icons mean") }, onClick = { menu = false; legend = true })
                    }
                }
                filter?.let { f ->
                    // The filter in use, one tap to clear, like Google Photos' search chips.
                    InputChip(
                        selected = true, onClick = { filter = null }, label = { Text(f.title) },
                        trailingIcon = { Icon(painterResource(R.drawable.ic_close), "Show all photos", Modifier.size(18.dp)) },
                        modifier = Modifier.padding(horizontal = 16.dp),
                    )
                }
                backup?.takeIf { it.running }?.let { BackupProgress(it) }
            }
        },
    ) { padding ->
        val list = sections
        when {
            list == null -> Unit
            list.isEmpty() -> if (filter != null) Text(
                "Nothing here.", style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(padding).padding(32.dp),
            ) else EmptyState(Modifier.padding(padding))
            else -> Grid(
                list, columns, grouping, padding, photos, selection, onSelection = { selection = it },
                onZoom = { step ->
                    level = (level + step).coerceIn(0, zoomLevels.lastIndex)
                    prefs.gridColumns = zoomLevels[level].first
                },
                onOpen = { entry ->
                    val all = list.flatMap { it.items }
                    onOpen(all, all.indexOf(entry))
                },
            )
        }
        if (selecting) {
            val byId = remember(list) { list.orEmpty().flatMap { it.items }.associateBy { it.id } }
            Box(Modifier.fillMaxSize().padding(bottom = padding.calculateBottomPadding()), contentAlignment = Alignment.BottomCenter) {
                SelectionActions(selection.mapNotNull(byId::get), onDone = { selection = emptySet() })
            }
        }
    }
    // Photos that went (deleted, filtered out) leave the selection.
    LaunchedEffect(sections) {
        val ids = sections?.flatMap { s -> s.items.map { it.id } }?.toHashSet() ?: return@LaunchedEffect
        if (selection.any { it !in ids }) selection = selection.filterTo(HashSet()) { it in ids }
    }
    if (legend) BadgeLegend(onDismiss = { legend = false })
}

/**
 * Phone photos and cloud items in one newest-first list, again whenever either side changes (iOS `GalleryModel`).
 * The demo shows only its sample library.
 */
fun galleryEntries(store: LibraryStore, photos: PhotoAccess, isDemo: Boolean): kotlinx.coroutines.flow.Flow<List<GalleryEntry>> {
    val phone = if (isDemo) flowOf(emptyList()) else photos.changes().map { photos.assets() }
    return combine(store.items(), phone) { items, assets -> Gallery.merge(assets, items) }.flowOn(Dispatchers.Default)
}

@Composable
private fun BackupProgress(b: DemoMode.Backup) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
        Text("Backing up ${b.done + b.current.size.coerceAtMost(b.total - b.done)} of ${b.total}…", style = MaterialTheme.typography.bodyMedium)
        LinearProgressIndicator(progress = { if (b.total == 0) 1f else b.done / b.total.toFloat() }, modifier = Modifier.fillMaxWidth().padding(top = 6.dp))
    }
}

@Composable
private fun EmptyState(modifier: Modifier) {
    Column(
        modifier.fillMaxSize().padding(32.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(painterResource(R.drawable.ic_photos), contentDescription = null, modifier = Modifier.size(48.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Text("No photos yet", style = MaterialTheme.typography.titleLarge)
        Text(
            "Photos and videos on this phone, and everything in your Telegram backup, show up here.",
            style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun Grid(
    sections: List<Timeline.Section<GalleryEntry>>, columns: Int, grouping: Timeline.Grouping, padding: PaddingValues,
    photos: PhotoAccess, selection: Set<String>, onSelection: (Set<String>) -> Unit, onZoom: (Int) -> Unit, onOpen: (GalleryEntry) -> Unit,
) {
    val haptics = androidx.compose.ui.platform.LocalHapticFeedback.current
    val order = remember(sections) { sections.flatMap { s -> s.items.map { it.id } } }
    val currentSelection by androidx.compose.runtime.rememberUpdatedState(selection)
    var edgeSpeed by remember { mutableStateOf(0f) }
    val edge = with(androidx.compose.ui.platform.LocalDensity.current) { 72.dp.toPx() }
    val side = LocalConfiguration.current.screenWidthDp.dp / columns
    val state = rememberLazyGridState()
    val titles = rememberTitles()
    // New items land above the newest section. A lazy grid keeps its place by key, so they would arrive off screen;
    // someone looking at the top keeps seeing the top, like Photos. Only the user's own scrolling moves the pin.
    var pinnedTop by remember { mutableStateOf(true) }
    LaunchedEffect(state) {
        snapshotFlow { state.firstVisibleItemIndex == 0 && state.firstVisibleItemScrollOffset == 0 }
            .collect { if (state.isScrollInProgress) pinnedTop = it }
    }
    val newest = sections.firstOrNull()?.items?.firstOrNull()?.id
    LaunchedEffect(newest) { if (pinnedTop) state.scrollToItem(0) }
    // Where each section's header sits in the grid: a header, then its tiles.
    val scrub = remember(sections, titles) {
        var index = 0
        sections.map { s -> ScrubSection(titles.title(s.title), index).also { index += 1 + s.items.size } }
    }
    Box(Modifier.fillMaxSize()) {
    LazyVerticalGrid(
        columns = GridCells.Fixed(columns),
        state = state,
        contentPadding = padding,
        horizontalArrangement = Arrangement.spacedBy(2.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
        modifier = Modifier.fillMaxSize().pinchToZoom(onZoom).dragToSelect(
            state, order = { order }, selection = { currentSelection }, onChange = onSelection,
            onStart = { haptics.performHapticFeedback(androidx.compose.ui.hapticfeedback.HapticFeedbackType.LongPress) },
            edge = edge, onEdge = { edgeSpeed = it },
        ),
    ) {
        for (section in sections) {
            item(key = "h:${grouping.name}:${section.key}", span = { GridItemSpan(maxLineSpan) }, contentType = "header") {
                Text(
                    titles.title(section.title),
                    style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 20.dp, bottom = 8.dp).semantics { heading() },
                )
            }
            items(section.items, key = { it.id }, contentType = { "cell" }) { entry ->
                val selected = entry.id in selection
                Cell(
                    entry, side, photos, selecting = selection.isNotEmpty(), selected = selected,
                    onClick = { if (selection.isNotEmpty()) onSelection(if (selected) selection - entry.id else selection + entry.id) else onOpen(entry) },
                    description = titles.describe(entry),
                )
            }
        }
    }
    DateScrubber(state, scrub, Modifier.align(Alignment.TopEnd).padding(padding))
    EdgeScroll(state, edgeSpeed)
    }
}

/**
 * A tile as the iPhone draws it: the backup badge top right on a small dark circle, the heart bottom left, then the
 * video length or the Live mark. On tiles under 40 dp only the badge stays.
 */
@Composable
private fun Cell(
    entry: GalleryEntry, side: Dp, photos: PhotoAccess, selecting: Boolean, selected: Boolean, onClick: () -> Unit, description: String,
) {
    // A selected tile shrinks inside its square, like Google Photos.
    val inset by androidx.compose.animation.core.animateDpAsState(if (selected) side * 0.08f else 0.dp, label = "inset")
    Box(
        Modifier.aspectRatio(1f).clickable(onClick = onClick)
            .semantics(mergeDescendants = true) {
                contentDescription = description
                if (selecting) this.selected = selected
            },
    ) {
        AsyncImage(
            model = entry.asset?.let { PhoneThumbnail(photos.uri(it)) } ?: entry.item?.let { DemoMode.assetUri(it) ?: CloudThumbnail(it) },
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier.fillMaxSize().padding(inset).clip(androidx.compose.foundation.shape.RoundedCornerShape(if (selected) 10.dp else 0.dp))
                .background(MaterialTheme.colorScheme.surfaceContainerHighest),
        )
        if (selecting) Icon(
            painterResource(if (selected) R.drawable.ic_check_circle else R.drawable.ic_circle_outline), null,
            Modifier.align(Alignment.TopStart).padding(6.dp).size(22.dp)
                .background(if (selected) Color.White else Color.Black.copy(alpha = 0.2f), androidx.compose.foundation.shape.CircleShape),
            tint = if (selected) Lelvo.colors.accent else Color.White,
        )
        BadgeMark(entry.badge, side, Modifier.align(Alignment.TopEnd).padding(if (side > 60.dp) 4.dp else 2.dp))
        if (side < 40.dp) return@Box
        Row(Modifier.align(Alignment.BottomStart).padding(start = 4.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            if (entry.isFavorite) {
                Icon(painterResource(R.drawable.ic_favorite), null, Modifier.size(14.dp), tint = Color.White)
                Spacer(Modifier.width(4.dp))
            }
            if (entry.isVideo) Text(
                formatDuration(entry.duration), color = Color.White, style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold,
            ) else if (entry.isLive) Icon(painterResource(R.drawable.ic_motion_photos), null, Modifier.size(14.dp), tint = Color.White)
        }
    }
}

/**
 * Two fingers change the column count; one finger is left to the grid's scrolling. Read in the Initial pass so the
 * grid never starts a scroll from a pinch.
 */
private fun Modifier.pinchToZoom(onZoom: (Int) -> Unit): Modifier = pointerInput(Unit) {
    awaitEachGesture {
        awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
        var zoom = 1f
        var fired = false
        do {
            val event = awaitPointerEvent(PointerEventPass.Initial)
            if (event.changes.count { it.pressed } >= 2) {
                zoom *= event.calculateZoom()
                if (!fired && zoom > 1.25f) { onZoom(-1); fired = true }
                if (!fired && zoom < 0.8f) { onZoom(1); fired = true }
                event.changes.forEach { it.consume() }
            }
        } while (event.changes.any { it.pressed })
    }
}

internal fun formatDuration(seconds: Double?): String {
    val s = (seconds ?: 0.0).toLong()
    return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s / 60 % 60, s % 60) else "%d:%02d".format(s / 60, s % 60)
}

/** Localized section titles and TalkBack descriptions; the formatters are made once per screen, not per cell. */
private class Titles(locale: Locale) {
    private val day = DateTimeFormatter.ofPattern(DateFormat.getBestDateTimePattern(locale, "EEEdMMMyyyy"), locale)
    private val month = DateTimeFormatter.ofPattern(DateFormat.getBestDateTimePattern(locale, "MMMMyyyy"), locale)
    private val full = DateTimeFormatter.ofPattern(DateFormat.getBestDateTimePattern(locale, "dMMMMyyyyjmm"), locale)

    fun title(t: Timeline.Title): String = when (t) {
        Timeline.Title.Today -> "Today"
        Timeline.Title.Yesterday -> "Yesterday"
        is Timeline.Title.Day -> day.format(t.date)
        is Timeline.Title.Month -> month.format(LocalDate.of(t.year, t.month, 1))
        is Timeline.Title.Year -> t.year.toString()
        Timeline.Title.Unknown -> "Unknown date"
    }

    fun describe(entry: GalleryEntry): String {
        val kind = when {
            entry.isVideo -> "Video, ${formatDuration(entry.duration)}"
            entry.isLive -> "Live Photo"
            else -> "Photo"
        }
        val date = entry.date?.let { full.format(Instant.ofEpochMilli(it).atZone(ZoneId.systemDefault())) } ?: "Unknown date"
        return listOfNotNull(kind, "Favorite".takeIf { entry.isFavorite }, date, entry.badge.label).joinToString(", ")
    }
}

@Composable
private fun rememberTitles(): Titles {
    val locale = LocalContext.current.resources.configuration.locales[0]
    return remember(locale) { Titles(locale) }
}
