package app.lelvo.android.search

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SuggestionChip
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.lelvo.android.LelvoApp
import app.lelvo.android.R
import app.lelvo.android.collections.Cover
import app.lelvo.android.shell.LelvoTopBar
import app.lelvo.android.timeline.TimelineScreen
import app.lelvo.android.ui.theme.Lelvo
import app.lelvo.core.index.GalleryEntry
import app.lelvo.core.index.GalleryFilter
import app.lelvo.core.search.SearchCorpus
import app.lelvo.core.search.SearchIndex
import app.lelvo.core.search.SearchMatcher
import app.lelvo.core.support.AppLog
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.withContext
import java.text.NumberFormat

/** The word index and suggestions, made together off the main thread whenever the library or known places change. */
private class SearchData(val index: SearchIndex, val suggestions: SearchCorpus.Suggestions, val byId: Map<String, GalleryEntry>)

/** Ids found for [query]; kept with it so results for older letters are never shown as the current ones. */
private class Found(val query: String, val ids: Set<String>)

/**
 * The last index made, kept while the app runs. Switching tabs disposes Search; without this, coming back to it in a
 * library of tens of thousands showed a blank screen for seconds while everything was listed and indexed again.
 */
@Volatile private var lastData: Pair<Boolean, SearchData>? = null

/** Sign out and reset: the next library mustn't show this one's index, even for a moment. */
internal fun forgetSearchIndex() { lastData = null }

/** How many rows a suggestion section shows before Show more, like iOS. */
private const val SHOWN = 4

/**
 * The Search tab (iOS `SearchView`), laid out the Google Photos way: a rounded search field under the title; under an
 * empty field, places as covers, then recent searches, months and a few things to try; while typing, the matching
 * photos as the timeline's own grid. Everything is found on this phone.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun SearchScreen(app: LelvoApp, onOpen: (List<GalleryEntry>, Int) -> Unit, onSettings: () -> Unit, modifier: Modifier = Modifier) {
    val isDemo by app.demo.active.collectAsState()
    val data by produceState(lastData?.takeIf { it.first == isDemo }?.second, isDemo) {
        app.model.gallery(isDemo)
            .combine(app.search.revision) { entries, _ -> entries }
            .flowOn(Dispatchers.Default)
            .collect { entries ->
                value = withContext(Dispatchers.Default) {
                    val started = System.currentTimeMillis()
                    val places = app.search.placeNames()
                    val built = SearchData(
                        SearchCorpus.index(entries, places, app.search::phoneLocation, things = { e -> e.asset?.let { app.search.things(it.localId) }.orEmpty() }),
                        SearchCorpus.suggestions(entries, places, app.search::phoneLocation),
                        entries.associateBy { it.id },
                    )
                    AppLog.info("Search: index of ${entries.size} items in %.2f s".format((System.currentTimeMillis() - started) / 1000.0))
                    built
                }
                lastData = isDemo to value!!
            }
    }
    var query by rememberSaveable { mutableStateOf("") }
    var recent by remember { mutableStateOf(app.prefs.recentSearches) }
    val searching = SearchMatcher.words(query).isNotEmpty()
    // A moment after the last letter, off the main thread (iOS waits 120 ms too).
    val found by produceState<Found?>(null, query, data) {
        val d = data ?: return@produceState
        val text = query
        if (SearchMatcher.words(text).isEmpty()) { value = null; return@produceState }
        delay(120)
        value = Found(text, withContext(Dispatchers.Default) { d.index.search(text).toHashSet() })
    }
    val focus = LocalFocusManager.current
    val remember = { text: String ->
        app.prefs.rememberSearch(text)
        recent = app.prefs.recentSearches
    }
    val choose = { text: String -> query = text; remember(text); focus.clearFocus() }
    // Back clears the search first, as in Google Photos.
    BackHandler(enabled = query.isNotEmpty()) { query = "" }

    Scaffold(
        modifier = modifier,
        topBar = {
            Column {
                LelvoTopBar("Search", app.demo, onSettings)
                SearchField(query, onChange = { query = it }, onSubmit = {
                    focus.clearFocus()
                    // Kept only when it finds something, like iOS.
                    if (found?.query == query && found?.ids?.isNotEmpty() == true) remember(query)
                })
            }
        },
    ) { padding ->
        val d = data
        val f = found
        when {
            d == null -> Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                androidx.compose.material3.CircularProgressIndicator()
            }
            !searching -> Suggestions(
                d, recent, app, PaddingValues(top = padding.calculateTopPadding(), bottom = 24.dp + padding.calculateBottomPadding()),
                onChoose = choose, onClearRecent = { app.prefs.recentSearches = emptyList(); recent = emptyList() },
            )
            // Still looking for these letters: the last results stay rather than flashing "No results".
            f == null -> Unit
            f.ids.isEmpty() && f.query == query -> NoResults(Modifier.padding(padding))
            f.ids.isEmpty() -> Unit
            else -> TimelineScreen(
                app.store, app.photos, app.demo, app.prefs,
                onOpen = { list, index -> remember(f.query); onOpen(list, index) },
                onSettings = onSettings,
                modifier = Modifier.padding(top = padding.calculateTopPadding()),
                collection = GalleryFilter.Matching(f.query.trim(), f.ids), embedded = true,
            )
        }
    }
}

@Composable
private fun SearchField(query: String, onChange: (String) -> Unit, onSubmit: () -> Unit) {
    TextField(
        value = query, onValueChange = onChange, singleLine = true,
        placeholder = { Text("Places, dates, albums, names", maxLines = 1, overflow = TextOverflow.Ellipsis) },
        leadingIcon = { Icon(painterResource(R.drawable.ic_search), contentDescription = null) },
        trailingIcon = {
            if (query.isNotEmpty()) IconButton(onClick = { onChange("") }) { Icon(painterResource(R.drawable.ic_close), "Clear search") }
        },
        shape = RoundedCornerShape(28.dp),
        colors = TextFieldDefaults.colors(
            focusedContainerColor = Lelvo.colors.fill, unfocusedContainerColor = Lelvo.colors.fill,
            focusedIndicatorColor = Color.Transparent, unfocusedIndicatorColor = Color.Transparent,
        ),
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
        keyboardActions = KeyboardActions(onSearch = { onSubmit() }),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
    )
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun Suggestions(
    d: SearchData, recent: List<String>, app: LelvoApp, padding: PaddingValues,
    onChoose: (String) -> Unit, onClearRecent: () -> Unit,
) {
    var expanded by rememberSaveable { mutableStateOf(emptyList<String>()) }
    val status by app.search.status.collectAsState()
    LazyColumn(Modifier.fillMaxSize(), contentPadding = padding) {
        val places = d.suggestions.places
        if (places.isNotEmpty()) item("places") {
            Header("Places")
            LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                items(places, key = { it.name }) { p ->
                    Column(
                        Modifier.width(104.dp).clip(RoundedCornerShape(12.dp)).clickable { onChoose(p.name) }
                            .semantics(mergeDescendants = true) { contentDescription = "${p.name}, ${p.count} items" },
                    ) {
                        Cover(d.byId[p.coverId], app, R.drawable.ic_place, Modifier.size(104.dp))
                        Text(p.name, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 6.dp))
                    }
                }
            }
        }
        fun section(title: String, rows: List<String>, icon: Int, trailing: (@Composable () -> Unit)? = null) {
            if (rows.isEmpty()) return
            item(title) {
                val open = title in expanded
                Header(title, trailing)
                (if (open) rows else rows.take(SHOWN)).forEach { SuggestionRow(it, icon) { onChoose(it) } }
                if (rows.size > SHOWN) TextButton(onClick = { expanded = if (open) expanded - title else expanded + title }, modifier = Modifier.padding(start = 4.dp)) {
                    Text(if (open) "Show less" else "Show more")
                }
            }
        }
        section("Recent", recent, R.drawable.ic_schedule) { TextButton(onClick = onClearRecent) { Text("Clear") } }
        section("Months", d.suggestions.months, R.drawable.ic_calendar)
        item("try") {
            Header("Try")
            FlowRow(Modifier.padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for (kind in listOf("Videos", "Favorites", "Screenshots")) SuggestionChip(onClick = { onChoose(kind) }, label = { Text(kind) })
            }
        }
        item("status") {
            val text = if (status.total == 0 || status.read >= status.total) "Search looks at places, dates, albums and file names, on this phone."
            else "${countFormat.format(status.read)} of ${countFormat.format(status.total)} photos read for places. Reading continues while Lelvo is open."
            Text(
                text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(16.dp, 24.dp, 16.dp, 0.dp),
            )
        }
    }
}

private val countFormat: NumberFormat = NumberFormat.getIntegerInstance()

@Composable
private fun Header(title: String, trailing: (@Composable () -> Unit)? = null) {
    Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 4.dp, top = 16.dp).heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f).semantics { heading() })
        trailing?.invoke()
    }
}

@Composable
private fun SuggestionRow(text: String, icon: Int, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).heightIn(min = 56.dp).padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(painterResource(icon), null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(text, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(start = 24.dp))
    }
}

@Composable
private fun NoResults(modifier: Modifier) {
    Column(
        modifier.fillMaxSize().padding(32.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(painterResource(R.drawable.ic_search), contentDescription = null, modifier = Modifier.size(48.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Text("No results", style = MaterialTheme.typography.titleLarge)
        Text(
            "Try a place, a month or year, an album or a file name.",
            style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center,
        )
    }
}
