package app.lelvo.android.timeline

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
    store: LibraryStore, demo: DemoMode, prefs: Prefs, onOpen: (List<LibraryItem>, Int) -> Unit, onSettings: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var level by rememberSaveable {
        mutableIntStateOf(zoomLevels.indexOfFirst { it.first == prefs.gridColumns }.takeIf { it >= 0 } ?: 1)
    }
    val (columns, grouping) = zoomLevels[level]
    // Sorting and grouping run off the main thread; the grid only lays out the result.
    val sections by produceState<List<Timeline.Section>?>(null, store, grouping) {
        store.items()
            .map { Timeline.group(Timeline.visible(it), grouping, ZoneId.systemDefault(), LocalDate.now()) }
            .flowOn(Dispatchers.Default)
            .collect { value = it }
    }
    val isDemo by demo.active.collectAsState()
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
            Column {
                LelvoTopBar("Photos", demo, onSettings, scrollBehavior) {
                    // Real backup is Phase I; until then only the demo simulates one.
                    if (isDemo) {
                        IconButton(onClick = { menu = true }) {
                            Icon(painterResource(R.drawable.ic_more_vert), contentDescription = "More options")
                        }
                        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                            DropdownMenuItem(
                                text = { Text("Back up now") },
                                enabled = backup?.running != true,
                                onClick = { menu = false; scope.launch { demo.runBackup() } },
                            )
                        }
                    }
                }
                backup?.takeIf { it.running }?.let { BackupProgress(it) }
            }
        },
    ) { padding ->
        val list = sections
        when {
            list == null -> Unit
            list.isEmpty() -> EmptyState(Modifier.padding(padding))
            else -> Grid(
                list, columns, grouping, padding,
                onZoom = { step ->
                    level = (level + step).coerceIn(0, zoomLevels.lastIndex)
                    prefs.gridColumns = zoomLevels[level].first
                },
                onOpen = { item ->
                    val all = list.flatMap { it.items }
                    onOpen(all, all.indexOf(item))
                },
            )
        }
    }
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
    sections: List<Timeline.Section>, columns: Int, grouping: Timeline.Grouping, padding: PaddingValues,
    onZoom: (Int) -> Unit, onOpen: (LibraryItem) -> Unit,
) {
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
    LazyVerticalGrid(
        columns = GridCells.Fixed(columns),
        state = state,
        contentPadding = padding,
        horizontalArrangement = Arrangement.spacedBy(2.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
        modifier = Modifier.fillMaxSize().pinchToZoom(onZoom),
    ) {
        for (section in sections) {
            item(key = "h:${grouping.name}:${section.key}", span = { GridItemSpan(maxLineSpan) }, contentType = "header") {
                Text(
                    titles.title(section.title),
                    style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 20.dp, bottom = 8.dp).semantics { heading() },
                )
            }
            items(section.items, key = { it.id }, contentType = { "cell" }) { item ->
                Cell(item, small = columns > 4, onClick = { onOpen(item) }, description = titles.describe(item))
            }
        }
    }
}

@Composable
private fun Cell(item: LibraryItem, small: Boolean, onClick: () -> Unit, description: String) {
    Box(
        Modifier.aspectRatio(1f).background(MaterialTheme.colorScheme.surfaceContainerHighest).clickable(onClick = onClick)
            .semantics(mergeDescendants = true) { contentDescription = description },
    ) {
        AsyncImage(
            model = DemoMode.assetUri(item),
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier.fillMaxSize(),
        )
        if (small) return@Box
        if (item.kind == ItemKind.Video) {
            Text(
                formatDuration(item.duration),
                color = Color.White, style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.align(Alignment.TopEnd).padding(6.dp),
            )
        }
        if (item.favorite) {
            Icon(
                painterResource(R.drawable.ic_favorite), contentDescription = null, tint = Color.White,
                modifier = Modifier.align(Alignment.BottomStart).padding(6.dp).size(14.dp),
            )
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

    fun describe(item: LibraryItem): String {
        val kind = if (item.kind == ItemKind.Video) "Video, ${formatDuration(item.duration)}" else "Photo"
        val date = item.createdAt?.let { full.format(Instant.ofEpochMilli(it).atZone(ZoneId.systemDefault())) } ?: "Unknown date"
        return listOfNotNull(kind, date, "Favorite".takeIf { item.favorite }).joinToString(", ")
    }
}

@Composable
private fun rememberTitles(): Titles {
    val locale = LocalContext.current.resources.configuration.locales[0]
    return remember(locale) { Titles(locale) }
}
