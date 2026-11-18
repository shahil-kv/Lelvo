package app.lelvo.android.timeline

import androidx.compose.foundation.lazy.grid.LazyGridState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import app.lelvo.android.LelvoApp
import app.lelvo.android.media.CloudThumbnail
import app.lelvo.core.ScrollLoadPolicy
import app.lelvo.core.index.GalleryEntry
import coil3.SingletonImageLoader
import coil3.request.ImageRequest
import coil3.size.Scale
import coil3.size.Size
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlin.math.abs

/** Most thumbnail prefetches running at once. */
private const val MAX_PREFETCHES = 2

/**
 * Grid scroll speed for [ScrollLoadPolicy]: attach [connection] to the grid; [deferring] is true while a fling is too
 * fast for new thumbnail loads to be worth starting, and [speed] is the smoothed dp per second.
 */
class ScrollLoading(private val density: Density) {
    private val policy = ScrollLoadPolicy()
    val deferring: MutableState<Boolean> = mutableStateOf(false)
    var speed = 0.0
        private set
    private var lastNanos = 0L

    val connection = object : NestedScrollConnection {
        override fun onPostScroll(consumed: Offset, available: Offset, source: NestedScrollSource): Offset {
            val now = System.nanoTime()
            val dt = (now - lastNanos) / 1e9
            lastNanos = now
            // A first event after a pause has no meaningful speed; very short gaps are frame jitter.
            if (dt > 0.25 || dt < 0.004) return Offset.Zero
            val dpPerSecond = abs(consumed.y) / density.density / dt
            speed = if (speed == 0.0) dpPerSecond else speed * 0.6 + dpPerSecond * 0.4
            deferring.value = policy.shouldDefer(speed)
            return Offset.Zero
        }
    }

    fun stopped() {
        speed = 0.0
        lastNanos = 0L
        policy.reset()
        deferring.value = false
    }
}

@Composable
fun rememberScrollLoading(state: LazyGridState): ScrollLoading {
    val density = LocalDensity.current
    val loading = remember { ScrollLoading(density) }
    LaunchedEffect(state) {
        snapshotFlow { state.isScrollInProgress }.collect { if (!it) loading.stopped() }
    }
    return loading
}

/**
 * Warms Coil's cache for the cloud thumbnails about two screens ahead in the scroll direction, with the same data and
 * size the tiles use. Restarting on every window change cancels the requests no longer needed. Nothing is fetched
 * ahead on a metered network (like iOS), while flinging, and never more than [MAX_PREFETCHES] at a time.
 * [entryAt] gives the grid item at an index (null for headers).
 */
@Composable
fun PrefetchAhead(state: LazyGridState, loading: ScrollLoading, columns: Int, sidePx: Int, entryAt: (Int) -> GalleryEntry?) {
    val context = LocalContext.current
    val app = context.applicationContext as LelvoApp
    val currentEntryAt by androidx.compose.runtime.rememberUpdatedState(entryAt)
    LaunchedEffect(state, columns, sidePx) {
        var lastFirst = state.firstVisibleItemIndex
        var forward = true
        snapshotFlow {
            val visible = state.layoutInfo.visibleItemsInfo
            Triple(visible.firstOrNull()?.index ?: 0, visible.lastOrNull()?.index ?: -1, loading.deferring.value)
        }.collectLatest { (first, last, deferring) ->
            if (first != lastFirst) { forward = first > lastFirst; lastFirst = first }
            if (deferring || last < 0 || sidePx <= 0 || app.isMetered()) return@collectLatest
            val screens = ScrollLoadPolicy.prefetchCount(loading.speed)
            val span = (last - first + 1) * screens
            if (span <= 0) return@collectLatest
            val targets = if (forward) (last + 1)..(last + span) else (first - 1) downTo (first - span)
            val loader = SingletonImageLoader.get(context)
            val permits = Semaphore(MAX_PREFETCHES)
            coroutineScope {
                for (index in targets) {
                    val item = currentEntryAt(index)?.takeIf { it.asset == null }?.item ?: continue
                    launch {
                        permits.withPermit {
                            loader.execute(
                                ImageRequest.Builder(context).data(CloudThumbnail(item)).size(Size(sidePx, sidePx)).scale(Scale.FILL).build(),
                            )
                        }
                    }
                }
            }
        }
    }
}
