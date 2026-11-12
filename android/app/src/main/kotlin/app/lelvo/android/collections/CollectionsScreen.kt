package app.lelvo.android.collections

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import app.lelvo.android.LelvoApp
import app.lelvo.android.R
import app.lelvo.android.media.CloudThumbnail
import app.lelvo.android.media.PhoneThumbnail
import app.lelvo.android.shell.LelvoTopBar
import app.lelvo.android.timeline.galleryEntries
import app.lelvo.core.index.Collections
import app.lelvo.core.index.GalleryEntry
import app.lelvo.core.index.GalleryFilter
import app.lelvo.core.index.ItemStatus
import app.lelvo.data.DemoMode
import coil3.compose.AsyncImage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onStart
import app.lelvo.core.memories.MemoryCard
import kotlinx.coroutines.flow.flowOn
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.text.NumberFormat

/** Where a tap in Collections goes; the screens open over the tabs (Google Photos hides the tab bar there too). */
sealed interface CollectionPage {
    data class Grid(val filter: GalleryFilter) : CollectionPage
    data class All(val title: String, val rows: List<Collections.Row>, val list: Boolean = false) : CollectionPage
    data object RecentlyDeleted : CollectionPage
    data class MemoryList(val cards: List<MemoryCard>, val byId: Map<String, GalleryEntry>) : CollectionPage
    /** A memory playing: the photos it plays, and every photo of it for Show all. */
    data class Story(val card: MemoryCard, val entries: List<GalleryEntry>, val allIds: Set<String>) : CollectionPage
    data object MemorySettings : CollectionPage
}

/** Everything Collections shows, made together off the main thread. */
private class CollectionsState(val content: Collections.Content, val memories: List<MemoryCard>, val byId: Map<String, GalleryEntry>)

/** How many covers a section shows before "See all", like iOS. */
private const val SHOWN = 4

/**
 * The Collections tab (iOS `AlbumsView`), laid out the Google Photos way: Recent days as a row of covers, albums two
 * across (Favorites first), the phone's folders ("On this device"), media types and Recently Deleted as plain rows.
 * Everything is counted off the main thread, once per change.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CollectionsScreen(app: LelvoApp, onOpen: (CollectionPage) -> Unit, onSettings: () -> Unit, modifier: Modifier = Modifier) {
    val isDemo by app.demo.active.collectAsState()
    val state by produceState<CollectionsState?>(null, isDemo) {
        val dayTitle = DateTimeFormatter.ofPattern("EEE, d MMM")
        // Memories are made again when a memory type is turned on or off.
        val memorySettings = app.prefs.changes().filter { it.startsWith("memories.") }.onStart { emit("") }
        galleryEntries(app.store, app.photos, isDemo)
            .combine(memorySettings) { entries, _ -> entries }
            // New places and place names (read for search) change memories and their titles.
            .combine(app.search.revision) { entries, _ -> entries }
            .map { entries ->
                CollectionsState(
                    Collections.build(entries, ZoneId.systemDefault(), LocalDate.now(), dayTitle::format),
                    memoryCards(entries, app.prefs, app.search), entries.associateBy { it.id },
                )
            }
            .flowOn(Dispatchers.Default)
            .collect { value = it }
    }
    val trashed by produceState(0, isDemo) {
        app.store.items().map { all -> all.count { it.status == ItemStatus.Trashed } }.flowOn(Dispatchers.Default).collect { value = it }
    }
    val scroll = TopAppBarDefaults.enterAlwaysScrollBehavior()
    Scaffold(
        modifier = modifier.nestedScroll(scroll.nestedScrollConnection),
        topBar = { LelvoTopBar("Collections", app.demo, onSettings, scroll) },
    ) { padding ->
        val st = state ?: return@Scaffold
        val c = st.content
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(top = padding.calculateTopPadding(), bottom = 24.dp + padding.calculateBottomPadding())) {
            if (st.memories.isNotEmpty()) item("memories") {
                Section("Memories", seeAll = { onOpen(CollectionPage.MemoryList(st.memories, st.byId)) }) {
                    MemoriesRow(st.memories.take(SHOWN), st.byId, app, onOpen)
                }
            }
            if (c.days.isNotEmpty()) item("days") {
                Section("Recent days", seeAll = if (c.days.size > SHOWN) ({ onOpen(CollectionPage.All("Recent days", c.days, list = true)) }) else null) {
                    CoverRow(c.days.take(SHOWN), app, onOpen)
                }
            }
            if (c.albums.isNotEmpty()) item("albums") {
                Section("Albums", seeAll = if (c.albums.size > SHOWN) ({ onOpen(CollectionPage.All("Albums", c.albums)) }) else null) {
                    TwoAcross(c.albums.take(SHOWN), app, onOpen)
                }
            }
            if (c.folders.isNotEmpty()) item("folders") {
                Section("On this device", seeAll = if (c.folders.size > SHOWN) ({ onOpen(CollectionPage.All("On this device", c.folders)) }) else null) {
                    CoverRow(c.folders.take(SHOWN), app, onOpen)
                }
            }
            if (c.media.isNotEmpty()) item("media") {
                Section("Media types") {
                    c.media.forEach { row -> LinkRow(row.filter.title, iconFor(row.filter), row.count) { onOpen(CollectionPage.Grid(row.filter)) } }
                }
            }
            item("utilities") {
                Section("Utilities") {
                    LinkRow("Recently Deleted", R.drawable.ic_delete, trashed) { onOpen(CollectionPage.RecentlyDeleted) }
                }
            }
        }
    }
}

private fun iconFor(f: GalleryFilter): Int = when (f) {
    GalleryFilter.Videos -> R.drawable.ic_videocam
    GalleryFilter.LivePhotos -> R.drawable.ic_motion_photos
    GalleryFilter.CloudOnly -> R.drawable.ic_cloud
    GalleryFilter.NotBackedUp -> R.drawable.ic_cloud_off
    GalleryFilter.Favorites -> R.drawable.ic_favorite
    is GalleryFilter.Folder -> R.drawable.ic_folder
    is GalleryFilter.Matching -> R.drawable.ic_calendar
    is GalleryFilter.Album -> R.drawable.ic_photo_library
}

private val countFormat: NumberFormat = NumberFormat.getIntegerInstance()

@Composable
private fun Section(title: String, seeAll: (() -> Unit)? = null, content: @Composable () -> Unit) {
    Column(Modifier.fillMaxWidth().padding(top = 16.dp)) {
        Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 4.dp).heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(title, style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f).semantics { heading() })
            if (seeAll != null) TextButton(onClick = seeAll) { Text("See all") }
        }
        content()
    }
}

/** Covers in a row that scrolls sideways (Recent days, folders). */
@Composable
private fun CoverRow(rows: List<Collections.Row>, app: LelvoApp, onOpen: (CollectionPage) -> Unit) {
    // A lazy row keeps its first item by key: a folder that turned up ahead of it (phone photos load after the
    // cloud's) left the row scrolled sideways. It starts at the beginning again whenever its covers change.
    androidx.compose.runtime.key(rows.map { it.filter }) {
        LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            items(rows, key = { it.filter.toString() }) { row -> CoverTile(row, app, 132.dp) { onOpen(CollectionPage.Grid(row.filter)) } }
        }
    }
}

/** Album covers two across, like Google Photos and iOS. */
@Composable
private fun TwoAcross(rows: List<Collections.Row>, app: LelvoApp, onOpen: (CollectionPage) -> Unit) {
    Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        rows.chunked(2).forEach { pair ->
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                pair.forEach { row -> Box(Modifier.weight(1f)) { CoverTile(row, app, null) { onOpen(CollectionPage.Grid(row.filter)) } } }
                if (pair.size == 1) Box(Modifier.weight(1f))
            }
        }
    }
}

@Composable
internal fun CoverTile(row: Collections.Row, app: LelvoApp, width: Dp?, onClick: () -> Unit) {
    val title = row.filter.title
    Column(
        (if (width != null) Modifier.width(width) else Modifier.fillMaxWidth())
            .clip(RoundedCornerShape(12.dp))
            .clickable(onClick = onClick)
            .semantics(mergeDescendants = true) { contentDescription = "$title, ${row.count} items" },
    ) {
        Cover(row.cover, app, iconFor(row.filter), Modifier.fillMaxWidth().aspectRatio(1f))
        Text(title, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 6.dp))
        Text(countFormat.format(row.count), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** A square cover from the grid's thumbnail cache, or the collection's icon when it's empty. */
@Composable
internal fun Cover(entry: GalleryEntry?, app: LelvoApp, icon: Int, modifier: Modifier) {
    Box(modifier.clip(RoundedCornerShape(12.dp)).background(MaterialTheme.colorScheme.surfaceVariant).clearAndSetSemantics { }, contentAlignment = Alignment.Center) {
        val model = entry?.asset?.let { PhoneThumbnail(app.photos.uri(it)) } ?: entry?.item?.let { DemoMode.assetUri(it) ?: CloudThumbnail(it) }
        if (model != null) AsyncImage(model, null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        else Icon(painterResource(icon), null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(36.dp))
    }
}

/** A plain list row: icon, title, count. */
@Composable
internal fun LinkRow(title: String, icon: Int, count: Int?, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).heightIn(min = 56.dp).padding(horizontal = 16.dp)
            .semantics(mergeDescendants = true) { contentDescription = if (count != null) "$title, $count items" else title },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(painterResource(icon), null, tint = MaterialTheme.colorScheme.primary)
        Text(title, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.padding(start = 24.dp).weight(1f))
        if (count != null) Text(countFormat.format(count), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** Every album, folder or day (See all). Days are a list, like iOS; albums and folders are covers. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AllCollectionsScreen(app: LelvoApp, page: CollectionPage.All, onOpen: (CollectionPage) -> Unit, onBack: () -> Unit) {
    androidx.activity.compose.BackHandler(onBack = onBack)
    Scaffold(
        topBar = {
            TopAppBar(
                navigationIcon = { IconButton(onClick = onBack) { Icon(painterResource(R.drawable.ic_arrow_back), "Back") } },
                title = { Text(page.title) },
            )
        },
    ) { padding ->
        if (page.list) LazyColumn(contentPadding = padding) {
            items(page.rows, key = { it.filter.toString() }) { row ->
                LinkRow(row.filter.title, iconFor(row.filter), row.count) { onOpen(CollectionPage.Grid(row.filter)) }
                HorizontalDivider()
            }
        } else LazyVerticalGrid(
            GridCells.Adaptive(160.dp), contentPadding = PaddingValues(16.dp, padding.calculateTopPadding() + 8.dp, 16.dp, 24.dp + padding.calculateBottomPadding()),
            horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            items(page.rows, key = { it.filter.toString() }) { row -> CoverTile(row, app, null) { onOpen(CollectionPage.Grid(row.filter)) } }
        }
    }
}
