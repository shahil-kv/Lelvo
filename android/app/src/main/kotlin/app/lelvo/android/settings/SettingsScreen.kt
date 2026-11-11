package app.lelvo.android.settings

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import app.lelvo.android.R
import app.lelvo.android.ui.theme.Lelvo

/** What Settings shows about the account and library; filled in by the caller. */
data class SettingsInfo(val account: String, val library: String, val version: String)

/**
 * Settings, as a plain Material list with section headers like Google Photos' settings (iOS `SettingsView` has the
 * same rows in grouped cards). This first version holds the account, the library and sign out; Phase K adds the rest.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(info: SettingsInfo, onClose: () -> Unit, onSignOut: () -> Unit, onCoreCheck: (() -> Unit)?) {
    BackHandler(onBack = onClose)
    var confirmSignOut by remember { mutableStateOf(false) }
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Settings") },
                navigationIcon = { IconButton(onClick = onClose) { Icon(painterResource(R.drawable.ic_arrow_back), contentDescription = "Back") } },
            )
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState())) {
            Header("Account")
            Row("Signed in as", info.account)
            Row("Library", info.library)
            if (onCoreCheck != null) {
                Divider()
                Header("Developer")
                Row("Core check", "Proves Android reads your library like the iPhone", onClick = onCoreCheck)
            }
            Divider()
            Header("About")
            Row("Version", info.version)
            Divider()
            Row("Sign out", null, destructive = true, onClick = { confirmSignOut = true })
        }
    }
    if (confirmSignOut) {
        AlertDialog(
            onDismissRequest = { confirmSignOut = false },
            title = { Text("Sign out of Lelvo?") },
            text = {
                Text("This phone is signed out of Telegram and Lelvo's local data is removed. Your backup in Telegram isn't touched; sign in again to get it back.")
            },
            confirmButton = {
                TextButton(onClick = { confirmSignOut = false; onSignOut() }) { Text("Sign out", color = Lelvo.colors.red) }
            },
            dismissButton = { TextButton(onClick = { confirmSignOut = false }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun Header(text: String) {
    Text(
        text, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 20.dp, bottom = 4.dp),
    )
}

@Composable
private fun Divider() = HorizontalDivider(Modifier.padding(top = 8.dp), color = Lelvo.colors.separator)

/** A setting: its name, and its value or a short explanation under it. */
@Composable
private fun Row(title: String, value: String?, destructive: Boolean = false, onClick: (() -> Unit)? = null) {
    ListItem(
        headlineContent = { Text(title, color = if (destructive) Lelvo.colors.red else MaterialTheme.colorScheme.onSurface) },
        supportingContent = value?.takeIf { it.isNotEmpty() }?.let { { Text(it, color = MaterialTheme.colorScheme.onSurfaceVariant) } },
        modifier = if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier,
    )
}
