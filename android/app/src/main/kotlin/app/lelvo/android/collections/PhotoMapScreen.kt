package app.lelvo.android.collections

import android.content.Context
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import app.lelvo.android.LelvoApp
import app.lelvo.android.R
import app.lelvo.android.media.CloudThumbnail
import app.lelvo.android.media.PhoneThumbnail
import app.lelvo.android.ui.theme.Lelvo
import app.lelvo.core.index.GalleryEntry
import app.lelvo.core.index.GalleryFilter
import app.lelvo.core.index.ItemKind
import app.lelvo.core.index.ItemStatus
import app.lelvo.core.index.LibraryItem
import app.lelvo.core.index.MapCluster
import app.lelvo.core.index.MapPin
import app.lelvo.core.index.PhotoMap
import app.lelvo.data.DemoMode
import coil3.compose.AsyncImage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.maplibre.android.MapLibre
import org.maplibre.android.camera.CameraUpdateFactory
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.geometry.LatLngBounds
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.MapView
import org.maplibre.android.maps.Style
import java.text.NumberFormat
import kotlin.math.roundToInt

/**
 * Every photo and video with a location, phone and cloud-only, on a map (iOS `PhotoMapView`, like Places in Photos
 * and Google Photos). Nearby photos group into one thumbnail, the newest taken there, with a count; tapping it opens
 * those photos. Only map tiles are fetched (OpenFreeMap, no account); the photos and their places stay on the phone.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PhotoMapScreen(app: LelvoApp, entries: List<GalleryEntry>, onOpen: (CollectionPage) -> Unit, onBack: () -> Unit) {
    BackHandler(onBack = onBack)
    val pins by produceState<List<MapPin>?>(null, entries) {
        val phone = app.search.phoneLocations()
        value = withContext(Dispatchers.Default) { PhotoMap.pins(entries) { phone[it] } }
    }
    val byId = remember(entries) { entries.associateBy { it.id } }
    Scaffold(topBar = {
        TopAppBar(title = { Text("Map") }, navigationIcon = { IconButton(onClick = onBack) { Icon(painterResource(R.drawable.ic_arrow_back), "Back") } })
    }) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            val list = pins
            when {
                list == null -> CircularProgressIndicator(Modifier.align(Alignment.Center))
                list.isEmpty() -> Column(Modifier.align(Alignment.Center).padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Icon(painterResource(R.drawable.ic_map), null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(48.dp))
                    Text("No Places", style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(top = 12.dp))
                    Text("Photos and videos with a location show here.", color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
                }
                else -> PhotoMap(list, byId, app, onOpen = { c ->
                    val n = c.count
                    onOpen(CollectionPage.Grid(GalleryFilter.Matching("${NumberFormat.getIntegerInstance().format(n)} item${if (n == 1) "" else "s"}", c.ids.toSet())))
                })
            }
        }
    }
}

@Composable
private fun PhotoMap(pins: List<MapPin>, byId: Map<String, GalleryEntry>, app: LelvoApp, onOpen: (MapCluster) -> Unit) {
    val context = LocalContext.current
    val density = LocalDensity.current
    val dark = MaterialTheme.colorScheme.background.luminance() < 0.5f
    val cellPx = with(density) { 64.dp.toPx() }
    var map by remember { mutableStateOf<MapLibreMap?>(null) }
    var clusters by remember { mutableStateOf<List<MapCluster>>(emptyList()) }
    // Bumped as the camera moves, so the thumbnails follow the map between groupings.
    var moved by remember { mutableStateOf(0) }
    val view = rememberMapView(context)

    fun regroup(m: MapLibreMap) {
        val w = view.width.toFloat(); val h = view.height.toFloat()
        clusters = PhotoMap.cluster(pins, cellPx) { p ->
            val pt = m.projection.toScreenLocation(LatLng(p.lat, p.lon))
            if (pt.x < -cellPx || pt.y < -cellPx || pt.x > w + cellPx || pt.y > h + cellPx) null else pt.x to pt.y
        }
    }

    LaunchedEffect(view, dark) {
        view.getMapAsync { m ->
            m.uiSettings.isRotateGesturesEnabled = false
            m.uiSettings.isTiltGesturesEnabled = false
            m.setStyle(Style.Builder().fromUri(if (dark) STYLE_DARK else STYLE_LIGHT)) {
                if (map == null) {
                    // The first view takes in every photo, as iOS does.
                    val b = PhotoMap.bounds(pins)!!
                    if (b.first == b.second) m.moveCamera(CameraUpdateFactory.newLatLngZoom(LatLng(b.first.first, b.first.second), 12.0))
                    else m.moveCamera(CameraUpdateFactory.newLatLngBounds(
                        LatLngBounds.Builder().include(LatLng(b.first.first, b.first.second)).include(LatLng(b.second.first, b.second.second)).build(),
                        with(density) { 72.dp.roundToPx() },
                    ))
                    m.addOnCameraMoveListener { moved++ }
                    m.addOnCameraIdleListener { regroup(m) }
                }
                map = m
                regroup(m)
            }
        }
    }

    Box(Modifier.fillMaxSize()) {
        AndroidView({ view }, Modifier.fillMaxSize())
        val m = map
        if (m != null) {
            val spots = remember(clusters, moved) { clusters.map { m.projection.toScreenLocation(LatLng(it.cover.lat, it.cover.lon)) } }
            for ((c, pt) in clusters.zip(spots)) androidx.compose.runtime.key(c.cover.id) {
                val entry = byId[c.cover.id]
                ClusterPin(entry, c.count, app, Modifier.offset { IntOffset((pt.x - 28.dp.toPx()).roundToInt(), (pt.y - 56.dp.toPx()).roundToInt()) }) { onOpen(c) }
            }
        }
    }
}

/** A square thumbnail with a white border and, for a group, a count badge in the accent (iOS `PhotoPinView`). */
@Composable
private fun ClusterPin(entry: GalleryEntry?, count: Int, app: LelvoApp, modifier: Modifier, onClick: () -> Unit) {
    val model: Any? = entry?.asset?.let { PhoneThumbnail(app.photos.uri(it)) } ?: entry?.item?.let { DemoMode.assetUri(it) ?: CloudThumbnail(it) }
    val text = NumberFormat.getIntegerInstance().format(count)
    Box(modifier.size(56.dp).semantics { role = Role.Button; contentDescription = if (count > 1) "$text photos here" else "1 photo here" }.clickable(onClick = onClick)) {
        Surface(shape = RoundedCornerShape(10.dp), shadowElevation = 3.dp, modifier = Modifier.size(56.dp)) {
            AsyncImage(
                model, null, contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize().background(Color.Gray.copy(alpha = 0.4f)).border(2.dp, Color.White, RoundedCornerShape(10.dp)).clip(RoundedCornerShape(10.dp)),
            )
        }
        if (count > 1) {
            Text(
                text, color = Color.White, style = MaterialTheme.typography.labelSmall, textAlign = TextAlign.Center,
                modifier = Modifier.align(Alignment.TopEnd).offset(x = 6.dp, y = (-6).dp).widthIn(min = 20.dp)
                    .shadow(2.dp, RoundedCornerShape(9.dp)).background(Lelvo.colors.accent, RoundedCornerShape(9.dp)).padding(horizontal = 5.dp, vertical = 1.dp),
            )
        }
    }
}

/** A MapLibre map view that follows the screen's lifecycle, so it pauses its drawing and network in the background. */
@Composable
internal fun rememberMapView(context: Context): MapView {
    val view = remember {
        MapLibre.getInstance(context.applicationContext)
        MapView(context).apply { onCreate(null) }
    }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle, view) {
        val observer = LifecycleEventObserver { _, e ->
            when (e) {
                Lifecycle.Event.ON_START -> view.onStart()
                Lifecycle.Event.ON_RESUME -> view.onResume()
                Lifecycle.Event.ON_PAUSE -> view.onPause()
                Lifecycle.Event.ON_STOP -> view.onStop()
                else -> Unit
            }
        }
        lifecycle.addObserver(observer)
        onDispose {
            lifecycle.removeObserver(observer)
            view.onPause(); view.onStop(); view.onDestroy()
        }
    }
    return view
}

/** OpenFreeMap's styles: free, no key, OpenStreetMap data (its attribution shows in the map's corner). */
internal const val STYLE_LIGHT = "https://tiles.openfreemap.org/styles/liberty"
internal const val STYLE_DARK = "https://tiles.openfreemap.org/styles/dark"

/**
 * A small still map of where one photo was taken, with a pin (iOS details sheet: a 2 km map with a marker). It doesn't
 * pan or zoom inside the sheet, so the sheet still scrolls; the row under it opens the phone's maps app.
 */
@Composable
fun LocationMap(lat: Double, lon: Double, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val dark = MaterialTheme.colorScheme.background.luminance() < 0.5f
    val view = rememberMapView(context)
    LaunchedEffect(view, lat, lon, dark) {
        view.getMapAsync { m ->
            m.uiSettings.setAllGesturesEnabled(false)
            m.uiSettings.isCompassEnabled = false
            m.uiSettings.isLogoEnabled = false
            m.setStyle(Style.Builder().fromUri(if (dark) STYLE_DARK else STYLE_LIGHT)) {
                m.moveCamera(CameraUpdateFactory.newLatLngZoom(LatLng(lat, lon), 13.5))
            }
        }
    }
    Box(modifier.clip(RoundedCornerShape(12.dp))) {
        AndroidView({ view }, Modifier.fillMaxSize())
        Icon(
            painterResource(R.drawable.ic_place), contentDescription = null, tint = Lelvo.colors.red,
            modifier = Modifier.align(Alignment.Center).offset(y = (-16).dp).size(36.dp),
        )
    }
}

/** Debug builds only (`--ez lelvo.map true`): the map with made-up places, and the details sheet's map. */
@Composable
internal fun MapPreview(app: LelvoApp, onClose: () -> Unit) {
    val sample = remember {
        val spots = listOf(12.9716 to 77.5946, 12.9750 to 77.6000, 12.9352 to 77.6245, 48.8584 to 2.2945, 40.6892 to -74.0445)
        spots.mapIndexed { i, (lat, lon) ->
            val item = LibraryItem(
                id = "preview$i", localId = null, sha256 = "", filename = "preview$i.jpg", kind = ItemKind.Photo,
                createdAt = 1_700_000_000_000 + i * 86_400_000L, fileSize = 0, status = ItemStatus.BackedUp,
                latitude = lat, longitude = lon,
            )
            GalleryEntry("cloud-preview$i", item.createdAt, null, item)
        }
    }
    Surface(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize()) {
            Box(Modifier.weight(1f)) { PhotoMapScreen(app, sample, onOpen = {}, onBack = onClose) }
            LocationMap(12.9716, 77.5946, Modifier.fillMaxWidth().height(180.dp).padding(16.dp))
        }
    }
}
