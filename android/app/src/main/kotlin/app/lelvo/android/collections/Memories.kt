package app.lelvo.android.collections

import app.lelvo.data.ProStore
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animate
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
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
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
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
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.layout
import androidx.compose.ui.unit.Constraints
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
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import app.lelvo.android.LelvoApp
import app.lelvo.android.R
import app.lelvo.android.ui.ProBadge
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
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import app.lelvo.data.DemoMode
import app.lelvo.data.Prefs
import coil3.compose.AsyncImage
import java.time.ZoneId
import kotlin.math.abs
import kotlin.math.min
import kotlin.math.roundToInt

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

private fun storyPage(card: MemoryCard, playlist: List<MemoryCard>, byId: Map<String, GalleryEntry>) = CollectionPage.Story(
    card, card.memory.ids.mapNotNull(byId::get), card.memory.allIds.toSet(), playlist, byId,
)

/** The image a memory shows for an entry: the phone's file, or a cloud photo's screen copy (no big download). */
@Composable
private fun storyModel(entry: GalleryEntry, app: LelvoApp): Any? =
    entry.asset?.let { app.photos.uri(it) }
        ?: entry.item?.let { DemoMode.assetUri(it) ?: if (app.media.hasScreenCopy(it)) CloudPhoto(it, screenCopy = true) else CloudThumbnail(it) }

/** Memories as a row of tall covers at the top of Collections, like Google Photos. */
@Composable
internal fun MemoriesRow(
    cards: List<MemoryCard>,
    byId: Map<String, GalleryEntry>,
    app: LelvoApp,
    onOpen: (CollectionPage) -> Unit,
    playlist: List<MemoryCard> = cards,
) {
    LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        items(cards, key = { it.id }) { card ->
            MemoryCover(card, byId[card.memory.cover], app, Modifier.width(150.dp).height(200.dp), big = false) {
                onOpen(storyPage(card, playlist, byId))
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
                    ) { onOpen(storyPage(card, page.cards, page.byId)) }
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
fun MemoriesSettingsScreen(app: LelvoApp, onBack: () -> Unit) {
    val prefs = app.prefs
    androidx.activity.compose.BackHandler(onBack = onBack)
    var kinds by remember { mutableStateOf(prefs.memoryKinds) }
    val isPro by app.pro.isPro.collectAsState()
    var openPro by remember { mutableStateOf(false) }
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
            if (isPro) {
                val on = Memories.KindFilter.Themes in kinds
                ListItem(
                    headlineContent = { Text("Themes: pets, beaches, food and more") },
                    trailingContent = { Switch(checked = on, onCheckedChange = null) },
                    modifier = Modifier.clickable(role = Role.Switch) {
                        prefs.setMemoryKind(Memories.KindFilter.Themes, !on)
                        kinds = prefs.memoryKinds
                    },
                )
            } else if (ProStore.OFFERED) {
                ListItem(
                    headlineContent = {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("Themes: pets, beaches, food and more")
                            ProBadge()
                        }
                    },
                    modifier = Modifier.clickable { openPro = true },
                )
            }
            Text(
                if (isPro || !ProStore.OFFERED) "Memories are made on this phone from your photos' dates, places and what's in them. Nothing is sent anywhere."
                else "On this day, recent highlights and trips stay free. Theme stories need Lelvo Pro.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(16.dp),
            )
        }
    }
    if (openPro) {
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { openPro = false },
            title = { Text("Lelvo Pro") },
            text = { Text("Theme memories are included with Lelvo Pro.") },
            confirmButton = { TextButton(onClick = { openPro = false }) { Text("OK") } },
        )
    }
}

private const val STORY_SECONDS = 4f

/**
 * A memory played like a story (iOS `MemoryStoryView`). The bar sits at the top with one progress line. Tap the sides
 * to move inside this memory, swipe sideways for the next or previous memory, swipe down or tap Close to leave.
 * A photo that won't load says so and the story moves on.
 */
@Composable
fun MemoryStoryScreen(app: LelvoApp, page: CollectionPage.Story, onShowAll: (MemoryCard) -> Unit, onClose: () -> Unit) {
    androidx.activity.compose.BackHandler(onBack = onClose)
    val playlist = if (page.playlist.isEmpty()) listOf(page.card) else page.playlist
    val start = playlist.indexOfFirst { it.id == page.card.id }.let { if (it < 0) 0 else it }
    var cardIndex by remember { mutableIntStateOf(start) }
    val card = playlist[cardIndex.coerceIn(0, playlist.lastIndex)]
    val entries = if (page.playlist.isEmpty()) page.entries else card.memory.ids.mapNotNull(page.byId::get)
    var index by remember { mutableIntStateOf(0) }
    var elapsed by remember { mutableFloatStateOf(0f) }
    var paused by remember { mutableStateOf(false) }
    var holding by remember { mutableStateOf(false) }
    var dragX by remember { mutableFloatStateOf(0f) }
    var dragY by remember { mutableFloatStateOf(0f) }
    val loaded = remember { mutableStateMapOf<String, Boolean>() } // true: shown; false: failed
    val reduceMotion = rememberReduceMotion()
    val haptics = LocalHapticFeedback.current
    val scope = rememberCoroutineScope()
    val close by androidx.compose.runtime.rememberUpdatedState(onClose)
    val cardIndexNow by androidx.compose.runtime.rememberUpdatedState(cardIndex)
    val settle = remember { androidx.compose.runtime.mutableStateOf<Job?>(null) }
    fun frameKey(item: MemoryCard, photo: Int) = "${item.id}#$photo"
    fun shift(delta: Int, haptic: Boolean = true) {
        val next = cardIndex + delta
        if (next !in playlist.indices) {
            dragX = 0f
            return
        }
        if (haptic) haptics.performHapticFeedback(HapticFeedbackType.SegmentTick)
        cardIndex = next
        index = 0
        elapsed = 0f
        holding = false
        dragX = 0f
        dragY = 0f
    }
    fun move(delta: Int) {
        val next = index + delta
        when {
            next >= entries.size -> if (cardIndex < playlist.lastIndex) shift(1, haptic = false) else close()
            next < 0 -> if (cardIndex > 0) shift(-1, haptic = false) else { elapsed = 0f; index = 0 }
            else -> { elapsed = 0f; holding = false; index = next }
        }
    }
    // One clock for the whole story: it stops while paused, held, or waiting for a photo that hasn't loaded yet.
    LaunchedEffect(card.id) {
        var last = 0L
        while (true) {
            withFrameNanos { now ->
                val dt = if (last == 0L) 0f else (now - last) / 1e9f
                last = now
                if (!paused && !holding && loaded.containsKey(frameKey(card, index))) {
                    elapsed += dt
                    if (elapsed >= STORY_SECONDS) move(1)
                }
            }
        }
    }
    if (entries.isEmpty()) LaunchedEffect(card.id) {
        when {
            cardIndex < playlist.lastIndex -> shift(1, haptic = false)
            cardIndex > 0 -> shift(-1, haptic = false)
            else -> close()
        }
    }
    // Runs after the finger lifts: the card finishes the slide, then the offset is cleared on the memory it landed on.
    suspend fun glide(vertical: Boolean, target: Float, commit: Int) {
        val start = if (vertical) dragY else dragX
        try {
            animate(
                initialValue = start, targetValue = target,
                animationSpec = if (vertical && target != 0f) tween(260) else spring(dampingRatio = 0.86f, stiffness = Spring.StiffnessMediumLow),
            ) { value, _ -> if (vertical) dragY = value else dragX = value }
            if (vertical && target != 0f) { close(); return }
            if (commit != 0) {
                val next = cardIndex + commit
                if (next in playlist.indices) {
                    haptics.performHapticFeedback(HapticFeedbackType.SegmentTick)
                    cardIndex = next
                    index = 0
                    elapsed = 0f
                }
            }
            dragX = 0f
            dragY = 0f
        } catch (e: CancellationException) { throw e }
    }
    val veil = 1f - min(1f, dragY.coerceAtLeast(0f) / 480f)
    // The black behind the card fades out with it. A solid page behind this used to stay after the photo had left.
    BoxWithConstraints(Modifier.fillMaxSize().background(Color.Black.copy(alpha = veil))) {
        val widthPx = constraints.maxWidth.toFloat()
        val pageWidth = maxWidth
        val gapPx = with(androidx.compose.ui.platform.LocalDensity.current) { 10.dp.toPx() }
        val widthRef by androidx.compose.runtime.rememberUpdatedState(widthPx)
        // The gesture stays on the still layer. Tracking the finger on the moving card made the page jump.
        // The row is three pages wide. Measured inside the screen it collapsed: the hidden page took the
        // whole width and the open memory was 0 wide, so the story was a black screen.
        Box(Modifier.fillMaxSize().clipToBounds().pointerInput(Unit) {
            val slop = 12.dp.toPx()
            val dismiss = 110.dp.toPx()
            awaitEachGesture {
                val down = awaitFirstDown(requireUnconsumed = false)
                if (down.position.y < 168.dp.toPx()) return@awaitEachGesture
                settle.value?.cancel()
                holding = true
                val downAt = System.nanoTime()
                var lastX = down.position.x
                var lastT = downAt
                var velocity = 0f
                var axis = 0 // 1 sideways, 2 down
                var dragged = false
                while (true) {
                    val event = awaitPointerEvent()
                    val change = event.changes.firstOrNull { it.id == down.id } ?: break
                    if (!change.pressed) break
                    val totalX = change.position.x - down.position.x
                    val totalY = change.position.y - down.position.y
                    val now = System.nanoTime()
                    val dt = (now - lastT) / 1e6f
                    if (dt > 0f) velocity = (change.position.x - lastX) / dt
                    lastX = change.position.x
                    lastT = now
                    if (axis == 0 && (abs(totalX) > slop || abs(totalY) > slop)) {
                        dragged = true
                        axis = if (abs(totalX) > abs(totalY)) 1 else 2
                    }
                    if (axis != 0) {
                        change.consume()
                        if (axis == 2 && totalY > 0f) {
                            dragX = 0f
                            dragY = totalY
                        } else if (axis == 1) {
                            dragY = 0f
                            val atEnd = (cardIndexNow == 0 && totalX > 0f) || (cardIndexNow == playlist.lastIndex && totalX < 0f)
                            dragX = if (atEnd) totalX * 0.32f else totalX
                        }
                    }
                }
                holding = false
                val totalX = lastX - down.position.x
                val totalY = dragY
                val held = System.nanoTime() - downAt > 220_000_000L
                val width = widthRef
                val flick = abs(velocity) > 1.1f
                when {
                    !dragged && !held -> move(if (down.position.x < width / 3f) -1 else 1)
                    axis == 2 && totalY > dismiss -> settle.value = scope.launch { glide(vertical = true, target = size.height.toFloat(), commit = 0) }
                    axis == 1 && (abs(totalX) > width * 0.22f || flick) -> {
                        val dir = if (totalX < 0f) 1 else -1
                        val dest = cardIndexNow + dir
                        if (dest !in playlist.indices) settle.value = scope.launch { glide(vertical = false, target = 0f, commit = 0) }
                        else settle.value = scope.launch { glide(vertical = false, target = dir * -(width + gapPx), commit = dir) }
                    }
                    dragged -> settle.value = scope.launch { glide(vertical = axis == 2, target = 0f, commit = 0) }
                }
            }
        }) {
            Row(
                Modifier.layout { measurable, constraints ->
                    val placeable = measurable.measure(constraints.copy(maxWidth = Constraints.Infinity))
                    layout(constraints.maxWidth, constraints.maxHeight) {
                        placeable.place((-(widthPx + gapPx) + dragX).roundToInt(), dragY.coerceAtLeast(0f).roundToInt())
                    }
                }.graphicsLayer {
                        val s = 1f - min(0.08f, dragY.coerceAtLeast(0f) / 1800f)
                        scaleX = s; scaleY = s
                    },
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                for (slot in -1..1) {
                    val item = playlist.getOrNull(cardIndex + slot)
                    val photos = when {
                        item == null -> emptyList()
                        page.playlist.isEmpty() && slot == 0 -> page.entries
                        else -> item.memory.ids.mapNotNull(page.byId::get)
                    }
                    StoryCard(
                        app, item, photos, photo = if (slot == 0) index else 0, elapsed = if (slot == 0) elapsed else 0f,
                        active = slot == 0, paused = paused, reduceMotion = reduceMotion, loaded = loaded,
                        onPause = { paused = !paused }, onShowAll = { item?.let(onShowAll) }, onClose = onClose,
                        modifier = Modifier.width(pageWidth).fillMaxHeight(),
                    )
                }
            }
        }
        Row(Modifier.fillMaxSize().zIndex(-1f)) {
            Box(Modifier.weight(1f).fillMaxSize().semantics { contentDescription = "Previous photo"; role = Role.Button; onClick { move(-1); true } })
            Box(Modifier.weight(2f).fillMaxSize().semantics { contentDescription = "Next photo"; role = Role.Button; onClick { move(1); true } })
        }
    }
}

@Composable
private fun StoryCard(
    app: LelvoApp, card: MemoryCard?, entries: List<GalleryEntry>, photo: Int, elapsed: Float, active: Boolean,
    paused: Boolean, reduceMotion: Boolean, loaded: androidx.compose.runtime.snapshots.SnapshotStateMap<String, Boolean>,
    onPause: () -> Unit, onShowAll: () -> Unit, onClose: () -> Unit, modifier: Modifier = Modifier,
) {
    val entry = entries.getOrNull(photo)
    val key = if (card == null || entry == null) "" else "${card.id}#$photo"
    Box(modifier.clip(RoundedCornerShape(16.dp)).background(Color.Black)) {
        if (card == null) return@Box
        if (entry == null) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text("No photos in this memory", color = Color.White, style = MaterialTheme.typography.bodyMedium)
            }
        } else {
            val zoom = if (!active || reduceMotion) 1f else 1f + 0.06f * (elapsed / STORY_SECONDS)
            AsyncImage(
                storyModel(entry, app), if (active) "Photo ${photo + 1} of ${entries.size}" else null,
                contentScale = ContentScale.Fit,
                onSuccess = { loaded[key] = true }, onError = { loaded[key] = false },
                modifier = Modifier.fillMaxSize().graphicsLayer { scaleX = zoom; scaleY = zoom },
            )
            if (active && loaded[key] == null) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp)
                }
            } else if (active && loaded[key] == false) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text("This photo couldn't load", color = Color.White, style = MaterialTheme.typography.bodyMedium)
                }
            }
            if (active) for (ahead in 1..2) entries.getOrNull(photo + ahead)?.let { next ->
                AsyncImage(
                    storyModel(next, app), null, Modifier.size(1.dp).graphicsLayer { alpha = 0f }.clearAndSetSemantics { },
                    onSuccess = { loaded["${card.id}#${photo + ahead}"] = true },
                    onError = { loaded["${card.id}#${photo + ahead}"] = false },
                )
            }
        }
        StoryChrome(card, entry, entries.size, photo, elapsed, paused, active, app, onPause, onShowAll, onClose)
    }
}

@Composable
private fun StoryChrome(
    card: MemoryCard, entry: GalleryEntry?, count: Int, index: Int, elapsed: Float, paused: Boolean, interactive: Boolean,
    app: LelvoApp, onPause: () -> Unit, onShowAll: () -> Unit, onClose: () -> Unit, modifier: Modifier = Modifier,
) {
    val shadow = Shadow(Color.Black.copy(alpha = 0.5f), blurRadius = 6f)
    Box(modifier.fillMaxWidth()) {
        Box(
            Modifier.fillMaxWidth().height(150.dp).background(
                Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.55f), Color.Transparent)),
            ),
        )
        Column(
            Modifier.fillMaxWidth()
                .windowInsetsPadding(WindowInsets.statusBars.union(WindowInsets.displayCutout))
                .padding(horizontal = 12.dp, vertical = 8.dp),
        ) {
            Row(Modifier.fillMaxWidth().height(3.dp).clearAndSetSemantics { }, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                val n = maxOf(count, 1)
                for (i in 0 until n) {
                    val fill = when {
                        !interactive || count == 0 -> 0f
                        i < index -> 1f
                        i > index -> 0f
                        else -> min(1f, elapsed / STORY_SECONDS)
                    }
                    Box(Modifier.weight(1f).height(3.dp).clip(RoundedCornerShape(2.dp)).background(Color.White.copy(alpha = 0.35f))) {
                        Box(Modifier.fillMaxHeight().fillMaxWidth(fill.coerceIn(0f, 1f)).background(Color.White))
                    }
                }
            }
            Row(Modifier.fillMaxWidth().padding(top = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                if (entry != null) {
                    AsyncImage(
                        storyModel(entry, app), null, contentScale = ContentScale.Crop,
                        modifier = Modifier.size(32.dp).clip(CircleShape),
                    )
                } else {
                    Box(Modifier.size(32.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.22f)))
                }
                Column(Modifier.weight(1f).padding(start = 8.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(card.title, color = Color.White, style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.SemiBold, shadow = shadow), maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(card.subtitle, color = Color.White, style = MaterialTheme.typography.bodySmall.copy(shadow = shadow), maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(start = 6.dp))
                    }
                    if (interactive) TextButton(onClick = onShowAll, contentPadding = PaddingValues(0.dp)) {
                        Text("Show All", color = Color.White, fontWeight = FontWeight.SemiBold)
                    }
                }
                if (interactive) {
                    IconButton(onClick = onPause) { Icon(painterResource(if (paused) R.drawable.ic_play else R.drawable.ic_pause), if (paused) "Play" else "Pause", tint = Color.White) }
                    IconButton(onClick = onClose) {
                        Box(Modifier.size(32.dp).background(Color.White.copy(alpha = 0.22f), CircleShape), contentAlignment = Alignment.Center) {
                            Icon(painterResource(R.drawable.ic_close), "Close", tint = Color.White, modifier = Modifier.size(16.dp))
                        }
                    }
                }
            }
        }
    }
}
