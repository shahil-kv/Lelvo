package app.lelvo.android.collections

import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import app.lelvo.android.LelvoApp
import app.lelvo.android.R
import app.lelvo.core.index.GalleryFilter
import app.lelvo.android.media.CloudPhoto
import app.lelvo.android.media.CloudThumbnail
import app.lelvo.android.media.PhoneThumbnail
import app.lelvo.android.ui.theme.rememberReduceMotion
import app.lelvo.core.index.GalleryEntry
import app.lelvo.core.memories.Memories
import app.lelvo.core.memories.MemoryCard
import app.lelvo.core.memories.MemoryCards
import app.lelvo.core.support.AppLog
import app.lelvo.data.DemoMode
import app.lelvo.data.Prefs
import coil3.compose.AsyncImage
import java.time.ZoneId
import kotlin.math.min

/**
 * Memories made on this phone from the timeline (iOS `MemoriesModel.cards`): photos only, with the phone file's place
 * (read by search) or the backup's, place names and things in photos (themes) from search. Screenshots never count.
 */
internal fun memoryCards(entries: List<GalleryEntry>, prefs: Prefs, search: app.lelvo.data.search.SearchService): List<MemoryCard> {
    val started = System.currentTimeMillis()
    val photos = entries.mapNotNull { e ->
        val date = e.date ?: return@mapNotNull null
        if (e.isVideo) return@mapNotNull null
        // The phone file's own place (read for search), else the backup's.
        val place = app.lelvo.core.search.SearchCorpus.location(e, search::phoneLocation)
        Memories.Photo(
            e.id, date, place?.first, place?.second,
            isUtility = e.asset?.bucketName == "Screenshots",
            things = e.asset?.let { search.things(it.localId) }.orEmpty(),
        )
    }
    val zone = ZoneId.systemDefault()
    val cards = MemoryCards.of(Memories.all(photos, System.currentTimeMillis(), zone, prefs.memoryKinds), zone, placeName = search::placeName)
    AppLog.info("Memories: ${cards.size} (${cards.joinToString { it.title }}) from ${entries.size} items in %.2f s".format((System.currentTimeMillis() - started) / 1000.0))
    return cards
}

/** The image a memory shows for an entry: the phone's file, or a cloud photo's screen copy (no big download). */
@Composable
private fun storyModel(entry: GalleryEntry, app: LelvoApp): Any? =
    entry.asset?.let { app.photos.uri(it) }
        ?: entry.item?.let { DemoMode.assetUri(it) ?: if (app.media.hasScreenCopy(it)) CloudPhoto(it, screenCopy = true) else CloudThumbnail(it) }

/** Memories as a row of tall covers at the top of Collections, like Google Photos. */
@Composable
internal fun MemoriesRow(cards: List<MemoryCard>, byId: Map<String, GalleryEntry>, app: LelvoApp, onOpen: (CollectionPage) -> Unit) {
    LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        items(cards, key = { it.id }) { card ->
            MemoryCover(card, byId[card.memory.cover], app, Modifier.width(150.dp).height(200.dp), big = false) {
                onOpen(CollectionPage.Story(card, card.memory.ids.mapNotNull(byId::get), card.memory.allIds.toSet()))
            }
        }
    }
}

@Composable
private fun MemoryCover(card: MemoryCard, cover: GalleryEntry?, app: LelvoApp, modifier: Modifier, big: Boolean, onLongClick: (() -> Unit)? = null, onClick: () -> Unit) {
    Box(
        modifier.clip(RoundedCornerShape(if (big) 16.dp else 12.dp)).background(MaterialTheme.colorScheme.surfaceVariant)
            .combinedClickable(onClick = onClick, onLongClick = onLongClick)
            .semantics(mergeDescendants = true) { contentDescription = "${card.title}, ${card.subtitle}. Plays the memory" },
    ) {
        if (cover != null) AsyncImage(
            cover.asset?.let { PhoneThumbnail(app.photos.uri(it)) } ?: cover.item?.let { DemoMode.assetUri(it) ?: CloudThumbnail(it) },
            null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize(),
        )
        Column(
            Modifier.align(Alignment.BottomStart).fillMaxWidth()
                .background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.6f))))
                .padding(if (big) 16.dp else 10.dp),
        ) {
            val shadow = Shadow(Color.Black.copy(alpha = 0.5f), blurRadius = 6f)
            Text(
                card.title, color = Color.White, maxLines = 2, overflow = TextOverflow.Ellipsis,
                style = (if (big) MaterialTheme.typography.headlineSmall else MaterialTheme.typography.titleSmall).copy(fontWeight = FontWeight.Bold, shadow = shadow),
            )
            Text(
                card.subtitle, color = Color.White, maxLines = 1, overflow = TextOverflow.Ellipsis,
                style = (if (big) MaterialTheme.typography.bodyMedium else MaterialTheme.typography.labelSmall).copy(shadow = shadow),
            )
        }
    }
}

/** Every memory, each a large cover (iOS `MemoriesView`); tap plays it, long press offers Show all photos. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MemoriesScreen(app: LelvoApp, page: CollectionPage.MemoryList, onOpen: (CollectionPage) -> Unit, onBack: () -> Unit) {
    androidx.activity.compose.BackHandler(onBack = onBack)
    var menuFor by remember { mutableStateOf<MemoryCard?>(null) }
    Scaffold(
        topBar = {
            TopAppBar(
                navigationIcon = { IconButton(onClick = onBack) { Icon(painterResource(R.drawable.ic_arrow_back), "Back") } },
                title = { Text("Memories") },
                actions = { IconButton(onClick = { onOpen(CollectionPage.MemorySettings) }) { Icon(painterResource(R.drawable.ic_settings), "Memories settings") } },
            )
        },
    ) { padding ->
        LazyColumn(contentPadding = PaddingValues(16.dp, padding.calculateTopPadding() + 8.dp, 16.dp, 24.dp + padding.calculateBottomPadding()), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            items(page.cards, key = { it.id }) { card ->
                Box {
                    MemoryCover(
                        card, page.byId[card.memory.cover], app, Modifier.fillMaxWidth().aspectRatio(4f / 3f), big = true,
                        onLongClick = { menuFor = card },
                    ) { onOpen(CollectionPage.Story(card, card.memory.ids.mapNotNull(page.byId::get), card.memory.allIds.toSet())) }
                    DropdownMenu(expanded = menuFor == card, onDismissRequest = { menuFor = null }) {
                        DropdownMenuItem(text = { Text("Show all photos") }, onClick = {
                            menuFor = null
                            onOpen(CollectionPage.Grid(GalleryFilter.Matching(card.title, card.memory.allIds.toSet())))
                        })
                    }
                }
            }
        }
    }
}

/** Which memory types to make, like Google Photos' Memories settings (iOS `MemoriesSettingsView`, same keys). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MemoriesSettingsScreen(prefs: Prefs, onBack: () -> Unit) {
    androidx.activity.compose.BackHandler(onBack = onBack)
    var kinds by remember { mutableStateOf(prefs.memoryKinds) }
    Scaffold(
        topBar = {
            TopAppBar(
                navigationIcon = { IconButton(onClick = onBack) { Icon(painterResource(R.drawable.ic_arrow_back), "Back") } },
                title = { Text("Memories") },
            )
        },
    ) { padding ->
        Column(Modifier.padding(padding)) {
            listOf(
                Memories.KindFilter.OnThisDay to "Years ago on this day",
                Memories.KindFilter.Recent to "Recent highlights",
                Memories.KindFilter.Trips to "Trips",
                // Themes need image labels, which Android doesn't make yet: no switch that does nothing.
            ).forEach { (kind, title) ->
                val on = kind in kinds
                ListItem(
                    headlineContent = { Text(title) },
                    trailingContent = { Switch(checked = on, onCheckedChange = null) },
                    modifier = Modifier.clickable(role = Role.Switch) {
                        prefs.setMemoryKind(kind, !on)
                        kinds = prefs.memoryKinds
                    },
                )
            }
            Text(
                "Memories are made on this phone from your photos' dates and places. Nothing is sent anywhere.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(16.dp),
            )
        }
    }
}

private const val STORY_SECONDS = 4f

/**
 * A memory played like Apple's and Google's (iOS `MemoryStoryView`): each photo for four seconds with a slow zoom,
 * cross-fading to the next, which is already loading. Tap the sides to move, hold to pause, swipe down to close.
 * A photo that won't load says so and the story moves on.
 */
@Composable
fun MemoryStoryScreen(app: LelvoApp, page: CollectionPage.Story, onShowAll: () -> Unit, onClose: () -> Unit) {
    androidx.activity.compose.BackHandler(onBack = onClose)
    val entries = page.entries
    var index by remember { mutableIntStateOf(0) }
    var elapsed by remember { mutableFloatStateOf(0f) }
    var paused by remember { mutableStateOf(false) }
    var holding by remember { mutableStateOf(false) }
    var dragY by remember { mutableFloatStateOf(0f) }
    val loaded = remember { mutableStateMapOf<Int, Boolean>() } // true: shown; false: failed
    val reduceMotion = rememberReduceMotion()
    val close by androidx.compose.runtime.rememberUpdatedState(onClose)
    fun move(delta: Int) {
        val next = index + delta
        if (next >= entries.size) { close(); return }
        elapsed = 0f
        holding = false
        index = maxOf(0, next)
    }
    // One clock for the whole story: it stops while paused, held, or waiting for a photo that hasn't loaded yet.
    LaunchedEffect(entries) {
        var last = 0L
        while (true) {
            withFrameNanos { now ->
                val dt = if (last == 0L) 0f else (now - last) / 1e9f
                last = now
                if (!paused && !holding && loaded.containsKey(index)) {
                    elapsed += dt
                    if (elapsed >= STORY_SECONDS) move(1)
                }
            }
        }
    }
    if (entries.isEmpty()) LaunchedEffect(Unit) { close() }
    Box(
        Modifier.fillMaxSize().background(Color.Black.copy(alpha = 1f - min(0.6f, dragY / 600f)))
            .pointerInput(Unit) {
                detectVerticalDragGestures(
                    onDragStart = { holding = true },
                    onVerticalDrag = { _, dy -> dragY = maxOf(0f, dragY + dy) },
                    onDragEnd = { holding = false; if (dragY > 140.dp.toPx()) close() else dragY = 0f },
                    onDragCancel = { holding = false; dragY = 0f },
                )
            }
            .pointerInput(Unit) {
                detectTapGestures(
                    onPress = { holding = true; tryAwaitRelease(); holding = false },
                    onTap = { pos -> move(if (pos.x < size.width / 3f) -1 else 1) },
                )
            },
    ) {
        Box(
            Modifier.fillMaxSize().graphicsLayer {
                translationY = dragY
                val s = 1f - min(0.25f, dragY / 1600f)
                scaleX = s; scaleY = s
            },
        ) {
            Crossfade(index, animationSpec = tween(500), label = "story") { i ->
                val entry = entries.getOrNull(i) ?: return@Crossfade
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    val zoom = if (reduceMotion || i != index) 1f else 1f + 0.06f * (elapsed / STORY_SECONDS)
                    AsyncImage(
                        storyModel(entry, app), "Photo ${i + 1} of ${entries.size}", contentScale = ContentScale.Fit,
                        onSuccess = { loaded[i] = true }, onError = { loaded[i] = false },
                        modifier = Modifier.fillMaxSize().graphicsLayer { scaleX = zoom; scaleY = zoom },
                    )
                    when (loaded[i]) {
                        null -> CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp)
                        false -> Text("This photo couldn't load", color = Color.White, style = MaterialTheme.typography.bodyMedium)
                        else -> Unit
                    }
                }
            }
            // The next two load while this one shows, so moving on never waits.
            for (ahead in 1..2) entries.getOrNull(index + ahead)?.let { e ->
                AsyncImage(storyModel(e, app), null, Modifier.size(1.dp).graphicsLayer { alpha = 0f }.clearAndSetSemantics { },
                    onSuccess = { loaded[index + ahead] = true }, onError = { loaded[index + ahead] = false })
            }
        }
        if (dragY == 0f) StoryChrome(page.card, entries.size, index, elapsed, paused, onPause = { paused = !paused }, onShowAll = onShowAll, onClose = onClose)
        // TalkBack: the sides as buttons, since the tap areas aren't views of their own.
        Row(Modifier.fillMaxSize().zIndex(-1f)) {
            Box(Modifier.weight(1f).fillMaxSize().semantics { contentDescription = "Previous photo"; role = Role.Button; onClick { move(-1); true } })
            Box(Modifier.weight(2f).fillMaxSize().semantics { contentDescription = "Next photo"; role = Role.Button; onClick { move(1); true } })
        }
    }
}

@Composable
private fun StoryChrome(card: MemoryCard, count: Int, index: Int, elapsed: Float, paused: Boolean, onPause: () -> Unit, onShowAll: () -> Unit, onClose: () -> Unit) {
    val shadow = Shadow(Color.Black.copy(alpha = 0.5f), blurRadius = 6f)
    Column(Modifier.fillMaxWidth().safeDrawingPadding().padding(16.dp)) {
        Row(Modifier.fillMaxWidth().clearAndSetSemantics { }, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
            for (i in 0 until count) {
                val fill = when {
                    i < index -> 1f
                    i == index -> min(1f, elapsed / STORY_SECONDS)
                    else -> 0f
                }
                Box(Modifier.weight(1f).height(3.dp).clip(RoundedCornerShape(2.dp)).background(Color.White.copy(alpha = 0.35f))) {
                    Box(Modifier.fillMaxWidth(fill).height(3.dp).background(Color.White))
                }
            }
        }
        Row(Modifier.fillMaxWidth().padding(top = 10.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(card.title, color = Color.White, style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.SemiBold, shadow = shadow))
                Text(card.subtitle, color = Color.White, style = MaterialTheme.typography.bodySmall.copy(shadow = shadow))
            }
            IconButton(onClick = onPause) { Icon(painterResource(if (paused) R.drawable.ic_play else R.drawable.ic_pause), if (paused) "Play" else "Pause", tint = Color.White) }
            TextButton(onClick = onShowAll) { Text("Show all", color = Color.White) }
            IconButton(onClick = onClose) { Icon(painterResource(R.drawable.ic_close), "Close", tint = Color.White) }
        }
    }
}
