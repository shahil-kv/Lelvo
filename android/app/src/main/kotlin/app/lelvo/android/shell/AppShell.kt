package app.lelvo.android.shell

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarScrollBehavior
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import app.lelvo.android.R
import app.lelvo.android.ui.theme.Lelvo
import app.lelvo.data.DemoMode
import kotlinx.coroutines.flow.MutableStateFlow

/** The four tabs, as on iPhone (iOS `RootView`): Settings opens from the gear on every tab. */
enum class Tab(val title: String, val icon: Int) {
    Photos("Photos", R.drawable.ic_photos),
    Collections("Collections", R.drawable.ic_collections),
    Search("Search", R.drawable.ic_search),
    Backup("Backup", R.drawable.ic_backup),
}

/**
 * The app after sign-in: a bottom navigation bar and one screen per tab. [content] draws the selected tab; it gets a
 * modifier that keeps it above the bar. Back on another tab returns to Photos, as Android apps with tabs do. The
 * selected tab lives in `AppModel`, so shortcuts can open one.
 */
@Composable
fun AppShell(selected: MutableStateFlow<Tab>, content: @Composable (tab: Tab, modifier: Modifier) -> Unit) {
    val tab by selected.collectAsState()
    BackHandler(enabled = tab != Tab.Photos) { selected.value = Tab.Photos }
    Scaffold(
        // Each tab's own top bar pads for the status bar; the shell owns only the bottom.
        contentWindowInsets = WindowInsets(0, 0, 0, 0),
        bottomBar = {
            NavigationBar(containerColor = Lelvo.colors.fill) {
                for (t in Tab.entries) {
                    NavigationBarItem(
                        selected = t == tab,
                        onClick = { selected.value = t },
                        icon = { Icon(painterResource(t.icon), contentDescription = null) },
                        label = { Text(t.title) },
                        colors = NavigationBarItemDefaults.colors(
                            selectedIconColor = MaterialTheme.colorScheme.primary,
                            selectedTextColor = MaterialTheme.colorScheme.primary,
                            indicatorColor = MaterialTheme.colorScheme.primaryContainer,
                        ),
                    )
                }
            }
        },
    ) { padding ->
        // The bar already pads for the system navigation; each tab's own Scaffold must not pad for it again.
        content(tab, Modifier.padding(bottom = padding.calculateBottomPadding()).consumeWindowInsets(WindowInsets.navigationBars))
    }
}

/** Every tab's top bar: its title, its own actions, the gear for Settings, and the demo banner under it. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LelvoTopBar(
    title: String,
    demo: DemoMode,
    onSettings: () -> Unit,
    scrollBehavior: TopAppBarScrollBehavior? = null,
    actions: @Composable RowScope.() -> Unit = {},
) {
    val isDemo by demo.active.collectAsState()
    Column {
        TopAppBar(
            title = { Text(title) },
            scrollBehavior = scrollBehavior,
            actions = {
                actions()
                IconButton(onClick = onSettings) { Icon(painterResource(R.drawable.ic_settings), contentDescription = "Settings") }
            },
        )
        if (isDemo) DemoBanner()
    }
}

/** Always visible in the demo, so the sample library is never mistaken for a real one. */
@Composable
fun DemoBanner() {
    Surface(color = Lelvo.colors.fill) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(painterResource(R.drawable.ic_info), contentDescription = null, modifier = Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(
                "Demo library: sample photos, nothing is uploaded",
                style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/** A tab whose screen comes in a later phase. Says what will be there, with the iPhone's words. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TabPlaceholder(tab: Tab, demo: DemoMode, onSettings: () -> Unit, modifier: Modifier) {
    val (icon, title, message) = when (tab) {
        Tab.Collections -> Triple(R.drawable.ic_collections, "Collections", "Albums, favorites, videos, Recently Deleted and Memories show up here.")
        Tab.Search -> Triple(R.drawable.ic_search, "Search", "Search your library by date, place, album or name.")
        Tab.Backup -> Triple(R.drawable.ic_backup, "Backup", "What's backed up, what's waiting, and Back up now.")
        Tab.Photos -> Triple(R.drawable.ic_photos, "Photos", "")
    }
    Scaffold(modifier, topBar = { LelvoTopBar(tab.title, demo, onSettings) }) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).padding(32.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Icon(painterResource(icon), contentDescription = null, modifier = Modifier.size(48.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(title, style = MaterialTheme.typography.titleLarge)
            Text(message, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
        }
    }
}
