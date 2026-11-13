package app.lelvo.android.shell

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import app.lelvo.android.LelvoApp
import app.lelvo.android.R
import app.lelvo.android.settings.AppLinks
import app.lelvo.android.settings.openLink
import app.lelvo.android.ui.theme.Lelvo
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Once, a moment after the photos first show: Lelvo collects nothing, so it can't see what goes wrong or reach anyone.
 * The founder asks people to tell him in the Lelvo group. Never during setup, never in the demo (App Review).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun CommunityNote(app: LelvoApp) {
    val isDemo by app.demo.active.collectAsState()
    // Kept through rotation and a light/dark switch, which recreate the screen.
    var showing by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(isDemo) {
        if (isDemo || app.prefs.communityNoteShown || showing) return@LaunchedEffect
        // The photos first: someone who just signed in sees their library working before being asked anything.
        delay(3_000)
        showing = true
    }
    // A restored screen can bring back "showing" after it was closed in a previous run.
    if (!showing || app.prefs.communityNoteShown) return
    val context = LocalContext.current
    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    // Seen only once it's closed: if the app is killed while it shows, it comes back next time.
    val done = { app.prefs.communityNoteShown = true; showing = false }
    val close = { scope.launch { sheet.hide() }.invokeOnCompletion { done() } }
    ModalBottomSheet(onDismissRequest = { done() }, sheetState = sheet) {
        Column(Modifier.padding(start = 24.dp, end = 24.dp, bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Box(Modifier.size(48.dp).background(MaterialTheme.colorScheme.primaryContainer, CircleShape), contentAlignment = Alignment.Center) {
                Icon(painterResource(R.drawable.ic_chat), contentDescription = null, tint = Lelvo.colors.accent)
            }
            Text("Found a bug? Tell me", style = MaterialTheme.typography.headlineSmall, color = MaterialTheme.colorScheme.onSurface, modifier = Modifier.semantics { heading() })
            val body = MaterialTheme.typography.bodyLarge
            val muted = MaterialTheme.colorScheme.onSurfaceVariant
            Text(
                buildAnnotatedString {
                    withStyle(SpanStyle(color = MaterialTheme.colorScheme.onSurface, fontWeight = FontWeight.Medium)) { append("Lelvo collects nothing.") }
                    append(" No account with us, no analytics, no tracking. That keeps your photos private, but it also means we never see when something goes wrong, and we have no way to reach you.")
                },
                style = body, color = muted,
            )
            Text(
                "So tell us. Join the Lelvo group on Telegram to report a bug or ask for a feature. I read every message myself, reply, and fix what you find fast.",
                style = body, color = muted,
            )
            Text("No ads or promotions there. Only updates and your questions.", style = body, color = muted)
            Text("${AppLinks.DEVELOPER_NAME}, founder", style = MaterialTheme.typography.bodyMedium, color = muted)
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Button(
                    onClick = { done(); openLink(context, AppLinks.COMMUNITY) },
                    modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = Lelvo.colors.accent),
                ) { Text("Join the Lelvo group") }
                TextButton(onClick = { close() }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text("Not now") }
            }
        }
    }
}
