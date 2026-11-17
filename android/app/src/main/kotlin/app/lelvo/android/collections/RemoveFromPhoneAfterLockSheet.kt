package app.lelvo.android.collections

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import android.net.Uri
import app.lelvo.android.LelvoApp
import app.lelvo.android.media.PhoneThumbnail
import app.lelvo.core.index.BackupBadge
import app.lelvo.core.index.GalleryEntry
import app.lelvo.core.index.LibraryItem
import coil3.compose.AsyncImage

private const val PREVIEW = 5

/** Green (backed-up on phone) only — never phone-only / uploading. */
fun removableAfterLock(entries: List<GalleryEntry>): List<GalleryEntry> =
    entries.filter { it.badge == BackupBadge.BackedUp && it.asset != null && it.item?.localId != null }

fun mediaItemsAfterLock(entries: List<GalleryEntry>): List<LibraryItem> =
    entries.mapNotNull { it.item }

/**
 * After locking: free space on this phone without sounding like the photos are gone forever.
 * Keep is the safe default; delete is Photos/MediaStore only.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RemoveFromPhoneAfterLockSheet(
    app: LelvoApp,
    entries: List<GalleryEntry>,
    onKeep: () -> Unit,
    onDeleteFromPhotos: () -> Unit,
) {
    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val n = entries.size
    val lead = if (n == 1) "This photo is" else "These ${"%,d".format(n)} photos are"
    ModalBottomSheet(onDismissRequest = onKeep, sheetState = sheet) {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 28.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                "Free space on this phone?",
                style = MaterialTheme.typography.titleLarge,
                textAlign = TextAlign.Center,
            )
            Text(
                "$lead already backed up (green) and hidden in Lelvo. Deleting from Photos frees space on this phone only — the copies in Lelvo and Telegram stay.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(top = 8.dp),
            )
            PreviewRow(app, entries, Modifier.padding(vertical = 18.dp))
            Button(onClick = onKeep, modifier = Modifier.fillMaxWidth().height(48.dp)) {
                Text("Keep in Photos", fontWeight = FontWeight.SemiBold)
            }
            OutlinedButton(
                onClick = onDeleteFromPhotos,
                modifier = Modifier.fillMaxWidth().height(48.dp).padding(top = 10.dp),
            ) {
                Text("Delete from Photos app only", color = MaterialTheme.colorScheme.error, fontWeight = FontWeight.SemiBold)
            }
            Text(
                "Your Locked Folder and Telegram library are untouched.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(top = 12.dp),
            )
        }
    }
}

@Composable
private fun PreviewRow(app: LelvoApp, entries: List<GalleryEntry>, modifier: Modifier = Modifier) {
    val shown = entries.take(PREVIEW)
    val extra = entries.size - shown.size
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
        shown.forEachIndexed { index, entry ->
            Box(Modifier.size(56.dp).clip(RoundedCornerShape(8.dp))) {
                val uri: Uri? = entry.asset?.let { app.photos.uri(it) }
                if (uri != null) {
                    AsyncImage(
                        PhoneThumbnail(uri),
                        contentDescription = null,
                        modifier = Modifier.size(56.dp),
                        contentScale = ContentScale.Crop,
                    )
                } else {
                    Box(Modifier.size(56.dp).background(MaterialTheme.colorScheme.surfaceVariant))
                }
                if (index == shown.lastIndex && extra > 0) {
                    Box(
                        Modifier.size(56.dp).background(Color.Black.copy(alpha = 0.45f)),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text("+$extra", color = Color.White, fontWeight = FontWeight.Bold)
                    }
                }
            }
        }
    }
}
