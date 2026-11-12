package app.lelvo.android.settings

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import app.lelvo.android.BuildConfig
import app.lelvo.android.R
import app.lelvo.android.shell.Messages
import app.lelvo.core.support.AppLog
import app.lelvo.core.support.Feedback
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/** The iPhone app's links (iOS `AppLinks`), the same addresses. */
internal object AppLinks {
    const val REPOSITORY = "https://github.com/shahil-kv/Lelvo"
    const val FAQ = "https://github.com/shahil-kv/Lelvo/blob/main/docs/FAQ.md"
    const val PRIVACY = "https://lelvo.app/privacy"
    const val LICENSE = "https://www.gnu.org/licenses/gpl-3.0.html"
    const val DEVELOPER_NAME = "Shahil"
    const val DEVELOPER_EMAIL = "support@lelvo.app"
}

/** "0.1.0 (12)": the version and the build number, as About shows them (iOS `displayVersion`). */
internal val displayVersion: String get() = "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})"

internal fun openLink(context: Context, url: String) {
    try {
        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    } catch (_: ActivityNotFoundException) {
        Messages.show(Messages.Style.Failure, "No app can open this link", url)
    }
}

private fun copy(context: Context, label: String, text: String) {
    context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText(label, text))
}

/**
 * Logs (iOS `LogsView`): what Lelvo wrote, newest at the bottom, to share with the developer or clear. Secrets are
 * removed as each line is written, so what shows here is what a share sends.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun LogsScreen(onBack: () -> Unit) {
    BackHandler(onBack = onBack)
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var lines by remember { mutableStateOf<List<String>?>(null) }
    LaunchedEffect(Unit) { lines = withContext(Dispatchers.IO) { AppLog.contents().lines().filter { it.isNotBlank() } } }
    val list = rememberLazyListState()
    LaunchedEffect(lines) { lines?.let { if (it.isNotEmpty()) list.scrollToItem(it.lastIndex) } }
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Logs") },
                navigationIcon = { IconButton(onClick = onBack) { Icon(painterResource(R.drawable.ic_arrow_back), contentDescription = "Back") } },
                actions = {
                    IconButton(onClick = { scope.launch { shareLogs(context) } }) {
                        Icon(painterResource(R.drawable.ic_send), contentDescription = "Share logs")
                    }
                    IconButton(onClick = {
                        AppLog.clear()
                        lines = emptyList()
                        Messages.show(Messages.Style.Success, "Logs cleared")
                    }) { Icon(painterResource(R.drawable.ic_delete), contentDescription = "Clear logs") }
                },
            )
        },
    ) { padding ->
        SelectionContainer(Modifier.fillMaxSize().padding(padding)) {
            LazyColumn(state = list, modifier = Modifier.fillMaxSize()) {
                item {
                    Footnote("Phone numbers, API keys, channel IDs and file IDs are removed from logs before they are shown or shared.")
                }
                val shown = lines
                if (shown != null && shown.isEmpty()) item { Footnote("No log entries yet.") }
                if (shown != null) itemsIndexed(shown, key = { i, _ -> i }) { _, line ->
                    Text(
                        line, style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 1.dp),
                    )
                }
            }
        }
    }
}

/** The log as a file in the share folder (the only folder the FileProvider exposes), to the share sheet. */
private suspend fun shareLogs(context: Context) {
    val file = withContext(Dispatchers.IO) {
        File(context.cacheDir, "Share").apply { mkdirs() }.let { AppLog.export(File(it, "lelvo-log.txt")) }
    } ?: run { Messages.show(Messages.Style.Failure, "Couldn't share the logs", "Try again."); return }
    val uri = FileProvider.getUriForFile(context, "${context.packageName}.share", file)
    val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_STREAM, uri)
        .putExtra(Intent.EXTRA_SUBJECT, "Lelvo logs").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    context.startActivity(Intent.createChooser(send, "Share logs").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
}

private val feedbackEnvironment: Feedback.Environment
    get() = Feedback.Environment(
        app = "Android", version = displayVersion,
        device = listOf(Build.MANUFACTURER.replaceFirstChar { it.uppercase() }, Build.MODEL).distinct().joinToString(" "),
        os = "Android ${Build.VERSION.RELEASE}",
    )

/**
 * Report a problem / Suggest a feature (iOS `FeedbackView`): what helps, then an email to the developer or a GitHub
 * issue. Both open with the app version and phone filled in; the user sends it themselves.
 */
@Composable
internal fun FeedbackScreen(kind: Feedback.Kind, onLogs: () -> Unit, onBack: () -> Unit) {
    val context = LocalContext.current
    val bug = kind == Feedback.Kind.Bug
    fun copyAddress(noMailApp: Boolean = false) {
        copy(context, "Email address", AppLinks.DEVELOPER_EMAIL)
        Messages.show(Messages.Style.Info, if (noMailApp) "No mail app is set up. The address is copied." else "Address copied")
    }
    SettingsPage(if (bug) "Report a problem" else "Suggest a feature", onBack) {
        Text(
            "You're writing to ${AppLinks.DEVELOPER_NAME}, the one person who builds Lelvo. I read every message myself, so " +
                "a reply can take a little while, but I'll get back to you as soon as I can.",
            modifier = Modifier.padding(16.dp),
        )
        SectionDivider()
        SectionHeader(if (bug) "What helps me fix it" else "What helps")
        if (bug) {
            SettingRow("What you were doing, and what you expected", icon = R.drawable.ic_info_outline)
            SettingRow("What happened instead", icon = R.drawable.ic_error)
            SettingRow("A screen recording or screenshots", icon = R.drawable.ic_image)
            SettingRow("Your logs: open Logs and share the file", icon = R.drawable.ic_description, onClick = onLogs)
            Footnote("Phone numbers, API keys, channel IDs and file IDs are removed from logs before they're shared.")
        } else {
            SettingRow("What you'd like Lelvo to do", icon = R.drawable.ic_auto_awesome)
            SettingRow("Why it would help you", icon = R.drawable.ic_favorite_border)
            SettingRow("A screenshot or sketch, if it helps", icon = R.drawable.ic_image)
        }
        SectionDivider()
        SettingRow("Email ${AppLinks.DEVELOPER_NAME}", icon = R.drawable.ic_mail) {
            val url = Feedback.mailUrl(
                AppLinks.DEVELOPER_EMAIL, Feedback.subject(kind, "Lelvo"),
                Feedback.draft(kind, "Lelvo", AppLinks.DEVELOPER_NAME, feedbackEnvironment),
            )
            try {
                context.startActivity(Intent(Intent.ACTION_SENDTO, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            } catch (_: ActivityNotFoundException) {
                copyAddress(noMailApp = true)
            }
        }
        SettingRow(AppLinks.DEVELOPER_EMAIL, "Tap to copy", icon = R.drawable.ic_content_copy) { copyAddress() }
        SettingRow("Create an issue on GitHub", icon = R.drawable.ic_code) {
            openLink(context, Feedback.gitHubIssueUrl(AppLinks.REPOSITORY, kind, feedbackEnvironment))
        }
        Footnote(
            "Your mail app opens with a message ready for you to finish and send, with your app version and phone model " +
                "filled in. ${AppLinks.DEVELOPER_NAME} will see your email address. GitHub issues are public and need a GitHub account.",
        )
    }
}

/** About (iOS `AboutView`). */
@Composable
internal fun AboutScreen(onFeedback: (Feedback.Kind) -> Unit, onAcknowledgements: () -> Unit, onBack: () -> Unit) {
    val context = LocalContext.current
    SettingsPage("About", onBack) {
        SettingRow("Version", displayVersion)
        Text(
            "Lelvo backs up your photos to a private channel in your own Telegram account. No servers, no analytics, no ads.",
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
        )
        SectionDivider()
        SectionHeader("Help")
        SettingRow("Questions and answers", icon = R.drawable.ic_help) { openLink(context, AppLinks.FAQ) }
        SettingRow("Report a problem", icon = R.drawable.ic_error) { onFeedback(Feedback.Kind.Bug) }
        SettingRow("Suggest a feature", icon = R.drawable.ic_auto_awesome) { onFeedback(Feedback.Kind.Idea) }
        SettingRow("Privacy policy", icon = R.drawable.ic_lock) { openLink(context, AppLinks.PRIVACY) }
        SectionDivider()
        SectionHeader("Free and open source")
        Text(
            "Lelvo is free software: you can redistribute it and modify it under the terms of the GNU General Public " +
                "License, version 3. It comes with no warranty.",
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
        )
        SettingRow("Source code", icon = R.drawable.ic_code) { openLink(context, AppLinks.REPOSITORY) }
        SettingRow("GNU General Public License v3.0", icon = R.drawable.ic_description) { openLink(context, AppLinks.LICENSE) }
        SettingRow("Acknowledgements", icon = R.drawable.ic_favorite_border, onClick = onAcknowledgements)
        SectionDivider()
        SectionHeader("Telegram")
        Footnote("Lelvo uses the Telegram API. It isn't made, endorsed or supported by Telegram.")
    }
}

/** Third-party code inside the Android app and its licences (NOTICE.md lists the same). */
private val ACKNOWLEDGEMENTS = listOf(
    Triple("TDLib", "Telegram's client library: sign-in, uploads, downloads. Boost Software License 1.0.", "https://github.com/tdlib/td/blob/master/LICENSE_1_0.txt"),
    Triple("OpenSSL", "Cryptography inside TDLib. Apache License 2.0.", "https://www.openssl.org/source/license.html"),
    Triple("argon2kt", "Passphrase key derivation (Argon2id). MIT License.", "https://github.com/lambdapioneer/argon2kt/blob/main/LICENSE"),
    Triple("Argon2 reference implementation", "Inside argon2kt. CC0 1.0 or Apache License 2.0.", "https://github.com/P-H-C/phc-winner-argon2/blob/master/LICENSE"),
    Triple("Android Jetpack", "Compose, Material 3, Room, WorkManager, Media3 (ExoPlayer, Transformer) and AndroidX. Apache License 2.0.", "https://www.apache.org/licenses/LICENSE-2.0"),
    Triple("Kotlin and kotlinx", "The language, coroutines and serialization. Apache License 2.0.", "https://www.apache.org/licenses/LICENSE-2.0"),
    Triple("Coil", "Loading thumbnails and photos. Apache License 2.0.", "https://github.com/coil-kt/coil/blob/main/LICENSE.txt"),
    Triple("Telephoto", "Zooming into photos. Apache License 2.0.", "https://github.com/saket/telephoto/blob/trunk/LICENSE.txt"),
)

@Composable
internal fun AcknowledgementsScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    SettingsPage("Acknowledgements", onBack) {
        ACKNOWLEDGEMENTS.forEach { (name, detail, url) -> SettingRow(name, detail) { openLink(context, url) } }
        Footnote("Tap a name to read its licence.")
    }
}
