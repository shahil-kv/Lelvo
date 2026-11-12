package app.lelvo.android.settings

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import app.lelvo.android.LelvoApp
import app.lelvo.android.R
import app.lelvo.android.backup.SecondCopyScreen
import app.lelvo.android.collections.MemoriesSettingsScreen
import app.lelvo.android.shell.Messages
import app.lelvo.android.ui.theme.Lelvo
import app.lelvo.core.support.Feedback
import app.lelvo.telegram.TelegramException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/** What Settings shows about the account and library; filled in by the caller. */
data class SettingsInfo(val account: String, val library: String)

/** The pages under Settings, newest last; Back closes the top one. */
private sealed interface Page {
    data object BackupOptions : Page
    data object Albums : Page
    data object Memories : Page
    data object Storage : Page
    data object DownloadCopy : Page
    data object Encryption : Page
    data object Logs : Page
    data class Feedback(val kind: app.lelvo.core.support.Feedback.Kind) : Page
    data object About : Page
    data object Acknowledgements : Page
}

/** Telegram's longest setting: the account is kept for 2 years without use. */
private const val MAX_TTL_DAYS = 730

/**
 * Settings (iOS `SettingsView`), as a plain Material list with section headers like Google Photos' settings; each
 * row with more behind it opens its own page. [real] is false in the demo, which has no Telegram account to change.
 */
@Composable
fun SettingsScreen(
    app: LelvoApp, real: Boolean, info: SettingsInfo, onClose: () -> Unit, onSignOut: () -> Unit,
    onCoreCheck: (() -> Unit)?, onLibrary: (() -> Unit)?, onBackupRulesChanged: (rules: Boolean) -> Unit,
) {
    var pages by remember { mutableStateOf(emptyList<Page>()) }
    val open = { p: Page -> pages = pages + p }
    val back = { pages = pages.dropLast(1) }

    Main(app, real, info, onClose, onSignOut, onCoreCheck, onLibrary, onBackupRulesChanged, open, visible = pages.isEmpty())
    pages.forEachIndexed { i, page ->
        // Each page stays composed under the next, so Back returns to the same place.
        key(i, page) {
            Surface(Modifier.fillMaxSize()) {
                when (page) {
                    Page.BackupOptions -> BackupOptionsScreen(app.prefs, onAlbums = { open(Page.Albums) }, onRulesChanged = onBackupRulesChanged, onBack = back)
                    Page.Albums -> AlbumPickerScreen(app, onChanged = { onBackupRulesChanged(false) }, onBack = back)
                    Page.Memories -> MemoriesSettingsScreen(app.prefs, onBack = back)
                    Page.Storage -> StorageScreen(app, onBack = back)
                    Page.DownloadCopy -> SecondCopyScreen(app, back)
                    Page.Encryption -> EncryptionScreen(app, onBack = back)
                    Page.Logs -> LogsScreen(onBack = back)
                    is Page.Feedback -> FeedbackScreen(page.kind, onLogs = { open(Page.Logs) }, onBack = back)
                    Page.About -> AboutScreen(onFeedback = { open(Page.Feedback(it)) }, onAcknowledgements = { open(Page.Acknowledgements) }, onBack = back)
                    Page.Acknowledgements -> AcknowledgementsScreen(onBack = back)
                }
            }
        }
    }
}

@Composable
private fun Main(
    app: LelvoApp, real: Boolean, info: SettingsInfo, onClose: () -> Unit, onSignOut: () -> Unit,
    onCoreCheck: (() -> Unit)?, onLibrary: (() -> Unit)?, onBackupRulesChanged: (rules: Boolean) -> Unit,
    open: (Page) -> Unit, visible: Boolean,
) {
    var confirmSignOut by remember { mutableStateOf(false) }
    var ttl by remember { mutableStateOf<Int?>(null) }
    var auto by remember { mutableStateOf(app.prefs.autoBackup) }
    // Read again on coming back, so a change in Backup options shows in the summary.
    val summary = remember(visible) { backupSummary(app.prefs) }
    val storage = if (visible) storageTotal(app) else "…"
    LaunchedEffect(real) { if (real) ttl = app.telegram.accountTtlDays() }

    // Back: SettingsPage closes Settings; a page composed above it takes Back first.
    SettingsPage("Settings", onClose) {
        SectionHeader("Telegram")
        SettingRow("Signed in as", info.account, icon = R.drawable.ic_account_circle)
        SettingRow("Library", info.library, icon = R.drawable.ic_photo_library, onClick = onLibrary)
        SettingRow(
            "Encryption", if (real && app.library.needsHeaderUpgrade) "End-to-end · add a recovery key" else "End-to-end",
            icon = R.drawable.ic_lock, onClick = if (real) ({ open(Page.Encryption) }) else null,
        )
        ttl?.let { AccountKept(app, it) { ttl = MAX_TTL_DAYS } }

        if (real) {
            SectionDivider()
            SectionHeader("Backup")
            ToggleRow("Back up new photos automatically",
                if (auto) "New photos are backed up on their own, including overnight while charging."
                else "Nothing uploads on its own: use Back up now on the Backup tab, or Back up on the photos you choose.",
                auto, icon = R.drawable.ic_cloud_upload) { auto = it; app.prefs.autoBackup = it; onBackupRulesChanged(false) }
            SettingRow("Backup options", summary, icon = R.drawable.ic_tune) { open(Page.BackupOptions) }
        }

        SectionDivider()
        SettingRow("Memories", icon = R.drawable.ic_schedule) { open(Page.Memories) }
        SettingRow("Storage", storage, icon = R.drawable.ic_storage) { open(Page.Storage) }
        Footnote("Space used on this phone by cloud previews you've viewed. Your photos aren't affected.")

        if (real) {
            SectionDivider()
            SectionHeader("Your data")
            SettingRow("Download a copy of your library", "Everything you've backed up, saved to a folder or a USB drive. Your library is never locked in.",
                icon = R.drawable.ic_download) { open(Page.DownloadCopy) }
        }

        SectionDivider()
        SectionHeader("Help")
        SettingRow("Report a problem", icon = R.drawable.ic_error) { open(Page.Feedback(Feedback.Kind.Bug)) }
        SettingRow("Suggest a feature", icon = R.drawable.ic_auto_awesome) { open(Page.Feedback(Feedback.Kind.Idea)) }
        SettingRow("Logs", icon = R.drawable.ic_description) { open(Page.Logs) }
        SettingRow("About and licences", displayVersion, icon = R.drawable.ic_info_outline) { open(Page.About) }

        if (onCoreCheck != null) {
            SectionDivider()
            SectionHeader("Developer")
            SettingRow("Core check", "Proves Android reads your library like the iPhone", onClick = onCoreCheck)
        }

        SectionDivider()
        SettingRow("Sign out and reset this phone", icon = R.drawable.ic_logout, destructive = true) { confirmSignOut = true }
        Footnote("Signs out of Telegram on this phone and removes local data. Your Telegram library is not touched; sign in again to restore it.")
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

/**
 * Telegram deletes an account after months without use, and the library with it (iOS shows the same). Green when
 * it's kept for the longest Telegram allows; otherwise a warning with a button that sets it.
 */
@Composable
private fun AccountKept(app: LelvoApp, days: Int, onChanged: () -> Unit) {
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf(false) }
    if (days >= MAX_TTL_DAYS) {
        ListItem(
            leadingContent = { androidx.compose.material3.Icon(painterResource(R.drawable.ic_verified_user), null, tint = Lelvo.colors.green) },
            headlineContent = { Text("Account kept for 2 years without use", color = Lelvo.colors.green) },
        )
        return
    }
    val span = if (days >= 365) "${days / 365} year" else "${days / 30} months"
    Column(Modifier.padding(horizontal = 16.dp, vertical = 4.dp)) {
        ListItem(
            leadingContent = { androidx.compose.material3.Icon(painterResource(R.drawable.ic_warning), null, tint = Lelvo.colors.orange) },
            headlineContent = {
                Text("Telegram deletes your account after $span of inactivity, and your library with it.",
                    style = MaterialTheme.typography.bodyMedium, color = Lelvo.colors.orange)
            },
        )
        TextButton(enabled = !busy, onClick = {
            busy = true
            scope.launch {
                try {
                    app.telegram.setAccountTtl(MAX_TTL_DAYS)
                    onChanged()
                    Messages.show(Messages.Style.Success, "Set to 2 years")
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    Messages.show(Messages.Style.Failure, "Something went wrong", (e as? TelegramException)?.friendly ?: "Try again.")
                } finally {
                    busy = false
                }
            }
        }) { Text("Change to 2 years (the maximum)") }
    }
}
