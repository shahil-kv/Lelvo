package app.lelvo.android.settings

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.autofill.ContentType
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentType
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import app.lelvo.android.LelvoApp
import app.lelvo.android.R
import app.lelvo.android.library.LibrarySetup
import app.lelvo.android.library.NewLibraryPage
import app.lelvo.android.shell.Messages
import app.lelvo.android.ui.theme.Lelvo
import app.lelvo.data.LibraryException
import app.lelvo.data.LibraryService.ChannelChoice
import app.lelvo.telegram.TelegramException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

private fun Throwable.sentence(): String = when (this) {
    is LibraryException -> message.orEmpty()
    is TelegramException -> friendly
    else -> "Something went wrong. Try again."
}

/**
 * Settings → Library (iOS `LibrarySettingsView`): the libraries in this Telegram account, the current one first.
 * Tap another to switch, rename any, read the current one again, or make a new one. A plain Material list like
 * Google Photos' settings; dialogs where iOS uses sheets.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LibrariesScreen(app: LelvoApp, onClose: () -> Unit) {
    val scope = rememberCoroutineScope()
    var channels by remember { mutableStateOf<List<ChannelChoice>?>(null) }
    var reload by remember { mutableIntStateOf(0) }
    var busy by remember { mutableStateOf<String?>(null) }
    var switching by remember { mutableStateOf<ChannelChoice?>(null) }
    var renaming by remember { mutableStateOf<ChannelChoice?>(null) }
    var creating by remember { mutableStateOf<LibrarySetup?>(null) }
    val current = app.library.chatId

    LaunchedEffect(reload) {
        channels = runCatching { app.library.candidateChannels() }.getOrElse {
            if (it !is CancellationException) Messages.show(Messages.Style.Failure, "Couldn't load your libraries", it.sentence())
            channels ?: emptyList()
        }
    }

    creating?.let { setup ->
        NewLibraryPage(setup, onBack = { creating = null }, onCreated = { key ->
            creating = null
            app.model.createdLibrary(key)
        })
        return
    }

    BackHandler(enabled = busy == null, onBack = onClose)
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Library") },
                navigationIcon = { IconButton(onClick = onClose, enabled = busy == null) { Icon(painterResource(R.drawable.ic_arrow_back), "Back") } },
            )
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState())) {
            // Always takes its line, so the list doesn't jump when work starts.
            Box(Modifier.fillMaxWidth().height(4.dp)) { if (busy != null) LinearProgressIndicator(Modifier.fillMaxWidth()) }
            Text(
                "Your photos live in one library at a time. Tap another to switch; nothing is deleted from either.",
                style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(16.dp),
            )
            val libraries = channels?.filter { it.isLibrary }?.sortedWith(compareBy({ it.id != current }, { it.title.lowercase() }))
            if (libraries == null) Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                Text("Looking for your libraries…", Modifier.padding(start = 12.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            libraries?.forEach { c ->
                val isCurrent = c.id == current
                ListItem(
                    leadingContent = { LibraryTile(c.encrypted) },
                    headlineContent = { Text(c.title) },
                    supportingContent = {
                        Text(
                            when {
                                isCurrent -> "In use · end-to-end encrypted"
                                c.encrypted -> "End-to-end encrypted"
                                else -> "Standard. Open it in Lelvo on iPhone or Mac."
                            },
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    },
                    trailingContent = {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            if (isCurrent) Icon(painterResource(R.drawable.ic_check_circle), "In use", tint = Lelvo.colors.accent)
                            IconButton(onClick = { renaming = c }, enabled = busy == null) { Icon(painterResource(R.drawable.ic_edit), "Rename ${c.title}") }
                        }
                    },
                    modifier = Modifier.clickable(enabled = busy == null && !isCurrent && c.encrypted) { switching = c },
                )
            }
            HorizontalDivider(Modifier.padding(top = 8.dp), color = Lelvo.colors.separator)
            ListItem(
                leadingContent = { Icon(painterResource(R.drawable.ic_sync), null) },
                headlineContent = { Text("Re-scan the current library") },
                supportingContent = { Text("Reads it from Telegram again", color = MaterialTheme.colorScheme.onSurfaceVariant) },
                modifier = Modifier.clickable(enabled = busy == null && current != null) {
                    busy = "Re-scanning…"
                    scope.launch {
                        try {
                            val s = app.model.rescan()
                            Messages.show(Messages.Style.Success, "Library re-scanned",
                                "${s.items} items found" + (if (s.incomplete > 0) ", ${s.incomplete} incomplete" else "") +
                                    (if (s.orphans > 0) ", ${s.orphans} duplicate uploads" else "") + ".")
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: Exception) {
                            Messages.show(Messages.Style.Failure, "Couldn't re-scan", e.sentence())
                        } finally {
                            busy = null
                        }
                    }
                },
            )
            ListItem(
                leadingContent = { Icon(painterResource(R.drawable.ic_add_circle), null) },
                headlineContent = { Text("New library") },
                supportingContent = { Text("Empty and end-to-end encrypted. Your current library stays as it is.", color = MaterialTheme.colorScheme.onSurfaceVariant) },
                modifier = Modifier.clickable(enabled = busy == null) {
                    creating = LibrarySetup(app.library, scope).also { it.load() }
                },
            )
        }
    }

    switching?.let { c ->
        SwitchDialog(c, onDismiss = { switching = null }) { secret, fail ->
            busy = "Switching to ${c.title}…"
            scope.launch {
                try {
                    app.model.switchLibrary(c.id, secret)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    // Wrong passphrase or unreachable: still on the library this phone was using, keys and all.
                    busy = null
                    fail(e.sentence())
                    return@launch
                }
                switching = null
                reload++
                busy = "Loading ${c.title}…"
                try {
                    val s = app.model.rescan()
                    Messages.show(Messages.Style.Success, "Switched to ${c.title}", "${s.items} items")
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    Messages.show(Messages.Style.Failure, "Switched to ${c.title}", "Couldn't read it yet. ${e.sentence()}")
                } finally {
                    busy = null
                }
            }
        }
    }

    renaming?.let { c ->
        RenameDialog(c.title, onDismiss = { renaming = null }) { title ->
            renaming = null
            busy = "Renaming…"
            scope.launch {
                try {
                    app.library.rename(c.id, title)
                    reload++
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    Messages.show(Messages.Style.Failure, "Couldn't rename", e.sentence())
                } finally {
                    busy = null
                }
            }
        }
    }
}

@Composable
private fun LibraryTile(encrypted: Boolean) {
    Box(
        Modifier.size(40.dp).clip(RoundedCornerShape(11.dp)).background(
            Brush.linearGradient(if (encrypted) listOf(Color(0xFFAF52DE), Color(0xFF5856D6)) else listOf(Color(0xFF007AFF), Color(0xFF5856D6))),
        ),
        contentAlignment = Alignment.Center,
    ) {
        Icon(painterResource(if (encrypted) R.drawable.ic_verified_user else R.drawable.ic_photo_library), null, Modifier.size(20.dp), tint = Color.White)
    }
}

/** Asks for the other library's passphrase; it's checked before this phone leaves the current library. */
@Composable
private fun SwitchDialog(c: ChannelChoice, onDismiss: () -> Unit, onSwitch: (String, (String) -> Unit) -> Unit) {
    var secret by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var working by remember { mutableStateOf(false) }
    val go = {
        if (secret.isNotEmpty() && !working) {
            working = true; error = null
            onSwitch(secret) { error = it; working = false }
        }
    }
    AlertDialog(
        onDismissRequest = { if (!working) onDismiss() },
        title = { Text("Switch to “${c.title}”?") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Lelvo loads this library from Telegram and links this phone's photos to it. Backups then go here.")
                OutlinedTextField(
                    secret, { secret = it; error = null }, singleLine = true, enabled = !working,
                    label = { Text("Passphrase or recovery key") }, isError = error != null,
                    supportingText = error?.let { { Text(it) } },
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                    modifier = Modifier.semantics { contentType = ContentType.Password },
                )
            }
        },
        confirmButton = { TextButton(onClick = { go() }, enabled = secret.isNotEmpty() && !working) { Text(if (working) "Switching…" else "Switch") } },
        dismissButton = { TextButton(onClick = onDismiss, enabled = !working) { Text("Cancel") } },
    )
}

@Composable
private fun RenameDialog(current: String, onDismiss: () -> Unit, onSave: (String) -> Unit) {
    var text by remember { mutableStateOf(current) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Rename library") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Only the name changes. Your photos stay where they are.")
                OutlinedTextField(text, { text = it }, singleLine = true, label = { Text("Name") })
            }
        },
        confirmButton = { TextButton(onClick = { onSave(text) }, enabled = text.isNotBlank()) { Text("Save") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
