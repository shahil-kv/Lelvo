package app.lelvo.android.timeline

import app.lelvo.core.index.ScrubberMark
import androidx.compose.foundation.shape.RoundedCornerShape
import app.lelvo.android.onboarding.appSettings
import androidx.lifecycle.compose.LifecycleResumeEffect
import app.lelvo.android.ui.theme.Lelvo
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.draw.clip
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.flow.onStart
import app.lelvo.data.media.PhotoAccess
import app.lelvo.core.index.date
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
import app.lelvo.android.actions.AlbumActions
import app.lelvo.android.LelvoApp
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
import androidx.compose.runtime.State as ComposeState
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
    /** Inside another screen (Search results): no top bar of its own, except while selecting. */
    embedded: Boolean = false,
) {
    var level by rememberSaveable {
        mutableIntStateOf(zoomLevels.indexOfFirst { it.first == prefs.gridColumns }.takeIf { it >= 0 } ?: 1)
    }
    val (columns, grouping) = zoomLevels[level]
    // Sorting and grouping run off the main thread; the grid only lays out the result.
    val isDemo by demo.active.collectAsState()
    // Only the Photos tab's menu picks a filter. A collection's own stays out of the saved state: a day or search
    // results can hold thousands of ids, too many for the bundle Android keeps when the app goes to the background.
    var menuFilter by rememberSaveable { mutableStateOf<GalleryFilter?>(null) }
    val filter = collection ?: menuFilter
    var legend by remember { mutableStateOf(false) }
    // Read again on every return, so the banner goes away once full access is allowed in Settings.
    var partialAccess by remember { mutableStateOf(false) }
    LifecycleResumeEffect(Unit) { partialAccess = photos.status() == PhotoAccess.Status.Partial; onPauseOrDispose {} }
    var deletingAlbum by remember { mutableStateOf(false) }
    var selection by remember { mutableStateOf(emptySet<String>()) }
    val selecting = selection.isNotEmpty()
    androidx.activity.compose.BackHandler(enabled = selecting) { selection = emptySet() }
    // Phone photos and cloud items in one timeline (iOS `GalleryModel.merge`); merging, filtering and grouping run off
    // the main thread, and a change to either side redraws only what moved.
    // A new filter (search results change with each letter) only filters again; the phone isn't listed again.
    val filterState = androidx.compose.runtime.rememberUpdatedState(filter)
    val model = (LocalContext.current.applicationContext as app.lelvo.android.LelvoApp).model
    val app = LocalContext.current.applicationContext as app.lelvo.android.LelvoApp
    val syncedLocked by app.lockedFolder.syncedLockedIds.collectAsState()
    val pendingLocked by app.lockedFolder.pendingLocalIds.collectAsState()
    // The Photos tab grows a page at a time. A filter or a collection needs its own set, so it reads the whole list.
    var pageLimit by rememberSaveable { mutableIntStateOf(FIRST_PAGE) }
    // Where the visible page starts in the whole library. The scrubber moves this instead of asking the grid to
    // lay out every row up to an old date, which is what made the handle stick.
    var windowStart by remember { mutableIntStateOf(0) }
    var pendingSkip by remember { mutableIntStateOf(0) }
    var scrubbing by remember { mutableStateOf(false) }
    val paging = collection == null && filter == null
    val dates by produceState(LongArray(0), paging, isDemo, photos) {
        if (!paging || isDemo) {
            value = LongArray(0)
            return@produceState
        }
        photos.changes().collect { value = photos.dates() }
    }
    // The date label follows the finger. The page loads when the finger lifts. Loading it during the drag
    // replaced hundreds of photos on the main thread, so the handle sat still on this phone.
    LaunchedEffect(pendingSkip, scrubbing) {
        if (scrubbing) return@LaunchedEffect
        if (pendingSkip != windowStart) {
            pageLimit = FIRST_PAGE
            windowStart = pendingSkip
        }
    }
    var galleryComplete by remember { mutableStateOf(false) }
    var galleryLoaded by remember { mutableIntStateOf(0) }
    val sections by produceState<List<Timeline.Section<GalleryEntry>>?>(
        null, store, grouping, isDemo, syncedLocked, pendingLocked, pageLimit, paging, windowStart,
    ) {
        val raw = if (paging) galleryWindow(store, photos, isDemo, pageLimit, windowStart)
        else model.gallery(isDemo).map { GalleryWindow(it, complete = true, loaded = Int.MAX_VALUE) }
        raw.combine(snapshotFlow { Triple(filterState.value, syncedLocked, pendingLocked) }) { window, (f, _, _) ->
                fun hidden(e: GalleryEntry) = app.lockedFolder.hidesFromTimeline(e)
                val list = when (f) {
                    is GalleryFilter.Locked -> window.entries.filter(::hidden)
                    null -> window.entries.filter { !hidden(it) }
                    else -> window.entries.filter { !hidden(it) }.filter(f::matches)
                }
                Triple(window.complete, window.loaded, Timeline.groupEntries(list, grouping, ZoneId.systemDefault(), LocalDate.now()))
            }
            .flowOn(Dispatchers.Default)
            .collect { (complete, loaded, grouped) ->
                galleryComplete = complete
                galleryLoaded = loaded
                value = grouped
            }
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
        // Embedded there's no bar to collapse. Material's enterAlways behaviour only learns how far it may move from
        // its TopAppBar; without one the limit stays unbounded and it eats every upward drag, so the grid never scrolls.
        modifier = if (embedded) modifier else modifier.nestedScroll(scrollBehavior.nestedScrollConnection),
        // Embedded, the screen around it already pads for the status bar.
        contentWindowInsets = if (embedded) androidx.compose.foundation.layout.WindowInsets(0, 0, 0, 0) else androidx.compose.material3.ScaffoldDefaults.contentWindowInsets,
        topBar = {
            if (selecting) TopAppBar(
                navigationIcon = { IconButton(onClick = { selection = emptySet() }) { Icon(painterResource(R.drawable.ic_close), "Clear selection") } },
                title = { Text("${selection.size} selected") },
                actions = {
                    TextButton(onClick = { selection = sections.orEmpty().flatMap { s -> s.items.map { it.id } }.toSet() }) { Text("Select all") }
                },
            ) else if (embedded) Unit
            else if (collection != null) TopAppBar(
                navigationIcon = { IconButton(onClick = onBack) { Icon(painterResource(R.drawable.ic_arrow_back), "Back") } },
                title = { Text(collection.title, maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis) },
                scrollBehavior = scrollBehavior,
                actions = {
                    IconButton(onClick = { menu = true }) { Icon(painterResource(R.drawable.ic_more_vert), contentDescription = "More options") }
                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        if (collection is GalleryFilter.Album) DropdownMenuItem(
                            text = { Text("Delete album", color = Lelvo.colors.red) },
                            onClick = { menu = false; deletingAlbum = true },
                        )
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
                            onClick = { menu = false; menuFilter = null },
                        )
                        for (f in GalleryFilter.entries) DropdownMenuItem(
                            text = { Text(f.title) },
                            trailingIcon = { if (filter == f) Icon(painterResource(R.drawable.ic_check_circle), null) },
                            onClick = { menu = false; menuFilter = f },
                        )
                        DropdownMenuItem(text = { Text("What the icons mean") }, onClick = { menu = false; legend = true })
                    }
                }
                filter?.let { f ->
                    // The filter in use, one tap to clear, like Google Photos' search chips.
                    InputChip(
                        selected = true, onClick = { menuFilter = null }, label = { Text(f.title) },
                        trailingIcon = { Icon(painterResource(R.drawable.ic_close), "Show all photos", Modifier.size(18.dp)) },
                        modifier = Modifier.padding(horizontal = 16.dp),
                    )
                }
                if (collection == null && filter == null && !isDemo && partialAccess) LimitedAccessBanner()
                backup?.takeIf { it.running }?.let { BackupProgress(it) }
            }
        },
    ) { padding ->
        val list = sections
        when {
            list == null -> Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    androidx.compose.material3.CircularProgressIndicator()
                    Text("Loading your photos", style = MaterialTheme.typography.bodyLarge)
                }
            }
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
                onNearEnd = {
                    // One more page per finished load, so a short screen can't jump straight to the whole library.
                    if (paging && !galleryComplete && galleryLoaded == pageLimit) pageLimit += FIRST_PAGE
                },
                dates = dates,
                windowStart = windowStart,
                onScrub = { index, dragging ->
                    pendingSkip = index
                    scrubbing = dragging
                },
            )
        }
        if (selecting) {
            val byId = remember(list) { list.orEmpty().flatMap { it.items }.associateBy { it.id } }
            Box(Modifier.fillMaxSize().padding(bottom = padding.calculateBottomPadding()), contentAlignment = Alignment.BottomCenter) {
                SelectionActions(
                    selection.mapNotNull(byId::get),
                    onDone = { selection = emptySet() },
                    album = (collection as? GalleryFilter.Album)?.name,
                    inLockedFolder = collection is GalleryFilter.Locked,
                )
            }
        }
    }
    // Photos that went (deleted, filtered out) leave the selection.
    LaunchedEffect(sections) {
        val ids = sections?.flatMap { s -> s.items.map { it.id } }?.toHashSet() ?: return@LaunchedEffect
        if (selection.any { it !in ids }) selection = selection.filterTo(HashSet()) { it in ids }
    }
    if (legend) BadgeLegend(onDismiss = { legend = false })
    (collection as? GalleryFilter.Album)?.let { album ->
        if (deletingAlbum) {
            val app = androidx.compose.ui.platform.LocalContext.current.applicationContext as LelvoApp
            androidx.compose.material3.AlertDialog(
                onDismissRequest = { deletingAlbum = false },
                title = { Text("Delete “${album.name}”?") },
                text = { Text("The album goes from Lelvo on all your devices. No photo is deleted.") },
                confirmButton = {
                    TextButton(onClick = {
                        deletingAlbum = false
                        scope.launch { if (AlbumActions.delete(app, album.name)) onBack() }
                    }) { Text("Delete album", color = Lelvo.colors.red) }
                },
                dismissButton = { TextButton(onClick = { deletingAlbum = false }) { Text("Cancel") } },
            )
        }
    }
}

/**
 * Phone photos and cloud items in one newest-first list, again whenever either side changes (iOS `GalleryModel`).
 * The demo shows only its sample library.
 */
/** Main timeline / search / memories: hide Locked Folder membership (iOS `GalleryModel.entries`). */
fun app.lelvo.android.LelvoApp.visibleGallery(isDemo: Boolean): kotlinx.coroutines.flow.Flow<List<GalleryEntry>> =
    model.gallery(isDemo)
        .combine(lockedFolder.syncedLockedIds) { entries, _ -> entries }
        .combine(lockedFolder.pendingLocalIds) { entries, _ ->
            entries.filter { !lockedFolder.hidesFromTimeline(it) }
        }

fun galleryEntries(store: LibraryStore, photos: PhotoAccess, isDemo: Boolean): kotlinx.coroutines.flow.Flow<List<GalleryEntry>> {
    // The first listing starts with the newest photos only, so the timeline draws at once on a big phone; the full
    // list follows. Later changes always list everything.
    val phone: kotlinx.coroutines.flow.Flow<PhonePage> = if (isDemo) flowOf(PhonePage(emptyList(), complete = true))
    else kotlinx.coroutines.flow.flow {
        var first = true
        photos.changes().collect {
            if (first) {
                first = false
                // The newest files, before the full library is ordered. Collections stays blank until this emits.
                val newest = photos.assetsRecent(FIRST_PAGE)
                if (newest.size == FIRST_PAGE) emit(PhonePage(newest, complete = false))
            }
            emit(PhonePage(photos.assets(), complete = true))
        }
    }
    // The index updates at most twice a second (LibraryStore.items), so a backup doesn't re-merge 30,000 photos per upload.
    // An empty list first: Collections was blank until every indexed photo had been read.
    val items = store.items().let { if (isDemo) it else it.onStart { emit(emptyList()) } }
    return combine(items, phone) { items, page ->
        val merged = Gallery.merge(page.assets, items, if (isDemo) emptyMap() else store.aliases())
        if (page.complete) merged
        else {
            // Only the part the newest photos cover is right yet: older cloud items would show as not on the phone.
            val oldest = page.assets.minOf { it.takenAt ?: it.addedAt ?: Long.MAX_VALUE }
            merged.filter { (it.date ?: Long.MIN_VALUE) >= oldest }
        }
    }.flowOn(Dispatchers.Default)
}

private class PhonePage(val assets: List<app.lelvo.core.index.PhoneAsset>, val complete: Boolean)

/** [preliminary] is the newest files only, shown while the whole library is still being ordered. */
private class PhoneSlice(val assets: List<app.lelvo.core.index.PhoneAsset>, val onPhone: Set<String>, val preliminary: Boolean)

/** The photos loaded so far. [complete] when scrolling further would add nothing. */
internal class GalleryWindow(val entries: List<GalleryEntry>, val complete: Boolean, val loaded: Int)

/**
 * The newest [limit] phone photos, plus the cloud items that belong in that same stretch of time. Grows when the
 * grid asks for more, instead of following the first screen with the whole library.
 */
internal fun galleryWindow(store: LibraryStore, photos: PhotoAccess, isDemo: Boolean, limit: Int, skip: Int = 0): kotlinx.coroutines.flow.Flow<GalleryWindow> {
    if (isDemo) return galleryEntries(store, photos, true).map { GalleryWindow(it, complete = true, loaded = limit) }
    // The phone page is read again only when the phone gallery changes. A backup rewrites the index constantly;
    // that must refresh badges, not list 30,000 photos again.
    val phone = kotlinx.coroutines.flow.flow {
        photos.changes().collect {
            if (skip == 0 && !photos.ranked()) {
                val fast = photos.assetsRecent(limit)
                emit(PhoneSlice(fast, fast.map { it.localId }.toSet(), preliminary = true))
            }
            emit(PhoneSlice(photos.assets(limit = limit, skip = skip), photos.localIds(), preliminary = false))
        }
    }
    return kotlinx.coroutines.flow.flow {
        kotlinx.coroutines.flow.combine(phone, store.changes()) { page, _ -> page }.collect { slice ->
            if (slice.preliminary) {
                emit(GalleryWindow(Gallery.merge(slice.assets, emptyList(), emptyMap()), complete = false, slice.assets.size))
                return@collect
            }
            val assets = slice.assets
            val onPhone = slice.onPhone
            val phoneDone = assets.size < limit
            val oldest = assets.minOfOrNull { it.date ?: Long.MIN_VALUE } ?: Long.MIN_VALUE
            val newest = assets.maxOfOrNull { it.date ?: Long.MIN_VALUE } ?: Long.MAX_VALUE
            val aliases = store.aliases()
            // A copy on the phone of a backed-up item: that item is on the phone too.
            val aliasOnPhone = aliases.filterKeys { it in onPhone }.values.toHashSet()
            val linked = store.itemsForPhone(assets.map { it.localId }) + store.items(assets.mapNotNull { aliases[it.localId] })
            // Blue is "only in the cloud". A photo still on the phone must not get it just because this page
            // hasn't reached that photo yet.
            val cloudRefs = store.backedUpRefs().filter { ref ->
                if (ref.hidden) return@filter false
                val local = ref.localId
                if (local != null && local in onPhone) return@filter false
                if (ref.id in aliasOnPhone) return@filter false
                if (assets.isNotEmpty() && !phoneDone) {
                    val created = ref.createdAt ?: Long.MIN_VALUE
                    // A page in the middle of the library only keeps cloud items from that same stretch of time.
                    if (created < oldest || created > newest) return@filter false
                }
                true
            }
            val shown = if (assets.isEmpty() || phoneDone) {
                cloudRefs.sortedByDescending { it.createdAt ?: Long.MIN_VALUE }.take(limit)
            } else cloudRefs
            val cloud = store.items(shown.map { it.id })
            val complete = if (assets.isEmpty()) cloudRefs.size <= limit else phoneDone && cloudRefs.size <= limit
            emit(GalleryWindow(Gallery.merge(assets, linked + cloud, aliases), complete, limit))
        }
    }.flowOn(Dispatchers.Default)
}

private const val FIRST_PAGE = 600

/** The first value at once, later ones at most every [ms] (the latest wins). */
internal fun <T> kotlinx.coroutines.flow.Flow<T>.throttled(ms: Long): kotlinx.coroutines.flow.Flow<T> = kotlinx.coroutines.flow.flow {
    var last = 0L
    conflate().collect {
        val wait = last + ms - System.currentTimeMillis()
        if (wait > 0) kotlinx.coroutines.delay(wait)
        last = System.currentTimeMillis()
        emit(it)
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
    sections: List<Timeline.Section<GalleryEntry>>, columns: Int, grouping: Timeline.Grouping, padding: PaddingValues,
    photos: PhotoAccess, selection: Set<String>, onSelection: (Set<String>) -> Unit, onZoom: (Int) -> Unit, onOpen: (GalleryEntry) -> Unit,
    onNearEnd: () -> Unit = {},
    dates: LongArray = LongArray(0),
    windowStart: Int = 0,
    onScrub: (index: Int, dragging: Boolean) -> Unit = { _, _ -> },
) {
    val haptics = androidx.compose.ui.platform.LocalHapticFeedback.current
    val order = remember(sections) { sections.flatMap { s -> s.items.map { it.id } } }
    // The gesture handler starts once; it must read the list as it is now, not as it was while the library loaded.
    val currentOrder by androidx.compose.runtime.rememberUpdatedState(order)
    val currentSelection by androidx.compose.runtime.rememberUpdatedState(selection)
    var edgeSpeed by remember { mutableStateOf(0f) }
    val edge = with(androidx.compose.ui.platform.LocalDensity.current) { 72.dp.toPx() }
    val side = LocalConfiguration.current.screenWidthDp.dp / columns
    val state = rememberLazyGridState()
    val scrollLoading = rememberScrollLoading(state)
    val flat = remember(sections) { sections.flatMap { s -> listOf<GalleryEntry?>(null) + s.items } }
    val sidePx = with(androidx.compose.ui.platform.LocalDensity.current) { side.roundToPx() }
    PrefetchAhead(state, scrollLoading, columns, sidePx) { flat.getOrNull(it) }
    val nearEnd by androidx.compose.runtime.rememberUpdatedState(onNearEnd)
    // Restart when a new page arrives, so staying at the bottom loads the page after that too.
    LaunchedEffect(state, sections) {
        snapshotFlow {
            val info = state.layoutInfo
            val total = info.totalItemsCount
            val last = info.visibleItemsInfo.lastOrNull()?.index ?: return@snapshotFlow false
            total > 0 && last >= total - 8
        }.collect { if (it) nearEnd() }
    }
    val titles = rememberTitles()
    // New items land above the newest section. A lazy grid keeps its place by key, so they would arrive off screen;
    // someone looking at the top keeps seeing the top, like Photos. Only the user's own scrolling moves the pin.
    var pinnedTop by remember { mutableStateOf(true) }
    LaunchedEffect(state) {
        snapshotFlow { state.firstVisibleItemIndex == 0 && state.firstVisibleItemScrollOffset == 0 }
            .collect { if (state.isScrollInProgress) pinnedTop = it }
    }
    val newest = sections.firstOrNull()?.items?.firstOrNull()?.id
    // A new photo at the real top stays in view. A scrubbed page must not be pulled back there.
    LaunchedEffect(newest) { if (pinnedTop && windowStart == 0) state.scrollToItem(0) }
    // The page under the finger changed: put that date at the top. Index 0 is already on screen, so this doesn't
    // walk the whole library the way a jump to an old row did.
    LaunchedEffect(newest) { if (windowStart > 0) state.requestScrollToItem(0) }
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
        modifier = Modifier.fillMaxSize().nestedScroll(scrollLoading.connection).pinchToZoom(onZoom).dragToSelect(
            state, order = { currentOrder }, selection = { currentSelection }, onChange = onSelection,
            onStart = { haptics.performHapticFeedback(androidx.compose.ui.hapticfeedback.HapticFeedbackType.LongPress) },
            edge = edge, onEdge = { edgeSpeed = it },
            onStep = { haptics.performHapticFeedback(androidx.compose.ui.hapticfeedback.HapticFeedbackType.SegmentTick) },
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
                    entry, side, photos, selecting = selection.isNotEmpty(), selected = selected, deferring = scrollLoading.deferring,
                    onClick = { if (selection.isNotEmpty()) onSelection(if (selected) selection - entry.id else selection + entry.id) else onOpen(entry) },
                    description = { titles.describe(entry) },
                )
            }
        }
    }
    var liveTitle by remember { mutableStateOf("") }
    // Same index mapping the scrubber uses (i = fraction * (size - 1)), in the zone the titles use; once per `dates`.
    val yearMarks = remember(dates) { yearMarksOf(dates) }
    DateScrubber(
        state, scrub, Modifier.align(Alignment.TopEnd).padding(padding),
        libraryStart = windowStart,
        libraryCount = dates.size,
        loadedCount = sections.sumOf { it.items.size }.coerceAtLeast(1),
        title = liveTitle,
        yearMarks = yearMarks,
        onFraction = if (dates.isEmpty()) null else { fraction, dragging ->
            val i = (fraction * (dates.size - 1)).toInt().coerceIn(0, dates.lastIndex)
            val next = titles.forEpoch(dates[i], grouping)
            if (next != liveTitle) {
                liveTitle = next
                haptics.performHapticFeedback(androidx.compose.ui.hapticfeedback.HapticFeedbackType.SegmentTick)
            }
            onScrub(i, dragging)
        },
    )
    EdgeScroll(state, edgeSpeed)
    }
}

/**
 * A tile as the iPhone draws it: the backup badge top right on a small dark circle, the heart bottom left, then the
 * video length or the Live mark. On tiles under 40 dp only the badge stays.
 */
@Composable
private fun Cell(
    entry: GalleryEntry, side: Dp, photos: PhotoAccess, selecting: Boolean, selected: Boolean, onClick: () -> Unit, description: () -> String,
    deferring: ComposeState<Boolean>,
) {
    // While a fast fling is on, a tile that never loaded keeps its placeholder; loads start once the speed drops.
    var loaded by remember(entry.id) { mutableStateOf(false) }
    // A selected tile shrinks inside its square, like Google Photos.
    val inset by androidx.compose.animation.core.animateDpAsState(if (selected) side * 0.08f else 0.dp, label = "inset")
    Box(
        Modifier.aspectRatio(1f).clickable(onClick = onClick)
            .semantics(mergeDescendants = true) {
                // Made only when TalkBack asks: formatting a date for every tile as it scrolls in cost frames.
                contentDescription = description()
                if (selecting) this.selected = selected
            },
    ) {
        AsyncImage(
            model = if (deferring.value && !loaded) null
                else entry.asset?.let { PhoneThumbnail(photos.uri(it)) } ?: entry.item?.let { DemoMode.assetUri(it) ?: CloudThumbnail(it) },
            onSuccess = { loaded = true },
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier.fillMaxSize().padding(inset).clip(androidx.compose.foundation.shape.RoundedCornerShape(if (selected) 10.dp else 0.dp))
                .background(MaterialTheme.colorScheme.surfaceContainerHighest),
        )
        // Cloud-only tiles with a ThumbHash show its blur until the real thumbnail is in.
        if (entry.asset == null) ThumbHashLayer(
            entry.item?.thumbHash, loaded, Modifier.fillMaxSize().padding(inset).clip(androidx.compose.foundation.shape.RoundedCornerShape(if (selected) 10.dp else 0.dp)),
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

/** First index of each run of one year in [dates] (newest first), as a fraction of `size - 1`. Unknown dates are skipped. */
private fun yearMarksOf(dates: LongArray): List<ScrubberMark> {
    if (dates.size < 2) return emptyList()
    val zone = ZoneId.systemDefault()
    val marks = ArrayList<ScrubberMark>()
    var year = Int.MIN_VALUE
    var from = Long.MAX_VALUE // the current year's range [from, to) in epoch ms, so most items skip the date maths
    var to = Long.MIN_VALUE
    for (i in dates.indices) {
        val ms = dates[i]
        if (ms <= 0L) continue
        if (ms in from until to) continue
        val date = Instant.ofEpochMilli(ms).atZone(zone).toLocalDate()
        from = LocalDate.of(date.year, 1, 1).atStartOfDay(zone).toInstant().toEpochMilli()
        to = LocalDate.of(date.year + 1, 1, 1).atStartOfDay(zone).toInstant().toEpochMilli()
        if (date.year != year) {
            year = date.year
            marks += ScrubberMark(year, i.toDouble() / (dates.size - 1))
        }
    }
    return marks
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

    /** The scrubber's date, in the same words as the section header. */
    fun forEpoch(epochMs: Long, grouping: Timeline.Grouping): String {
        if (epochMs <= 0L) return title(Timeline.Title.Unknown)
        val date = Instant.ofEpochMilli(epochMs).atZone(ZoneId.systemDefault()).toLocalDate()
        val today = LocalDate.now()
        val heading = when (grouping) {
            Timeline.Grouping.Day -> when (date) {
                today -> Timeline.Title.Today
                today.minusDays(1) -> Timeline.Title.Yesterday
                else -> Timeline.Title.Day(date)
            }
            Timeline.Grouping.Month -> Timeline.Title.Month(date.year, date.monthValue)
            Timeline.Grouping.Year -> Timeline.Title.Year(date.year)
        }
        return title(heading)
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

/** Like the iPhone's: the whole row opens this app's Settings page, where "Allow all" lives. */
@Composable
private fun LimitedAccessBanner() {
    val context = LocalContext.current
    Row(
        Modifier.padding(horizontal = 16.dp, vertical = 6.dp).fillMaxWidth().clip(RoundedCornerShape(12.dp))
            .background(Lelvo.colors.orange.copy(alpha = 0.12f))
            .clickable(onClickLabel = "Open Settings") { context.startActivity(appSettings(context.packageName)) }
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(painterResource(R.drawable.ic_warning), null, Modifier.size(18.dp), tint = Lelvo.colors.orange)
        Spacer(Modifier.width(10.dp))
        Text("Lelvo can only see the photos you selected.", style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f))
        Spacer(Modifier.width(8.dp))
        Text("Allow all", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
    }
}
