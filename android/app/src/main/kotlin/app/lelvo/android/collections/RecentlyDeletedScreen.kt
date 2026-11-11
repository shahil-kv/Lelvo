package app.lelvo.android.collections

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.lelvo.android.LelvoApp
import app.lelvo.android.R
import app.lelvo.android.media.CloudThumbnail
import app.lelvo.core.index.CloudTrash
import app.lelvo.core.index.ItemKind
import app.lelvo.core.index.LibraryItem
import app.lelvo.data.DemoMode
import coil3.compose.AsyncImage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/**
 * Items deleted from your Telegram library, kept 30 days (iOS `RecentlyDeletedView`), with the days left on each
 * tile like Google Photos' Trash. Recover and Delete send notes to the channel, so they come with Phase L.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RecentlyDeletedScreen(app: LelvoApp, onBack: () -> Unit) {
    androidx.activity.compose.BackHandler(onBack = onBack)
    val items by produceState<List<LibraryItem>?>(null) {
        app.store.items().map(CloudTrash::items).flowOn(Dispatchers.Default).collect { value = it }
    }
    Scaffold(
        topBar = {
            TopAppBar(
                navigationIcon = { IconButton(onClick = onBack) { Icon(painterResource(R.drawable.ic_arrow_back), "Back") } },
                title = { Text("Recently Deleted") },
            )
        },
    ) { padding ->
        val list = items ?: return@Scaffold
        if (list.isEmpty()) {
            Column(
                Modifier.fillMaxSize().padding(padding).padding(32.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Icon(painterResource(R.drawable.ic_delete), null, Modifier.size(48.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                Text("No recently deleted items", style = MaterialTheme.typography.titleLarge)
                Text(
                    "Items you delete from your backup stay here for 30 days before they're removed from your Telegram library.",
                    style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            return@Scaffold
        }
        val now = System.currentTimeMillis()
        val dateFormat = DateTimeFormatter.ofLocalizedDateTime(FormatStyle.LONG, FormatStyle.SHORT)
        LazyVerticalGrid(
            GridCells.Adaptive(110.dp), contentPadding = PaddingValues(top = padding.calculateTopPadding(), bottom = padding.calculateBottomPadding() + 24.dp),
            horizontalArrangement = Arrangement.spacedBy(2.dp), verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            item(span = { GridItemSpan(maxLineSpan) }, key = "note") {
                Text(
                    "Items stay here for 30 days, then they're removed from your Telegram library. Photos still on this phone aren't affected.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
                )
            }
            items(list, key = { it.id }) { item ->
                val days = CloudTrash.daysLeft(item, now)
                val left = if (days == 1) "1 day" else "$days days"
                val kind = if (item.kind == ItemKind.Video) "Video" else "Photo"
                val date = item.createdAt?.let { dateFormat.format(Instant.ofEpochMilli(it).atZone(ZoneId.systemDefault())) } ?: "Unknown date"
                Box(
                    Modifier.aspectRatio(1f).background(MaterialTheme.colorScheme.surfaceVariant)
                        .clearAndSetSemantics { contentDescription = "$kind, $date, $left left" },
                ) {
                    AsyncImage(DemoMode.assetUri(item) ?: CloudThumbnail(item), null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
                    Text(
                        left, color = Color.White,
                        style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.SemiBold, shadow = Shadow(Color.Black.copy(alpha = 0.6f), blurRadius = 4f)),
                        modifier = Modifier.align(Alignment.BottomStart).padding(5.dp),
                    )
                }
            }
        }
    }
}
