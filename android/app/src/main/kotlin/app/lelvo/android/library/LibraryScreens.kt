package app.lelvo.android.library

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
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
import androidx.compose.ui.semantics.contentType
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import app.lelvo.data.LibraryException
import app.lelvo.data.LibraryService
import app.lelvo.telegram.TelegramException
import kotlinx.coroutines.launch

private fun Throwable.sentence(): String = when (this) {
    is LibraryException -> message.orEmpty()
    is TelegramException -> friendly
    else -> "Something went wrong. Try again."
}

/** Finds the user's library among their channels (iOS: "Looking for your library…"). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChooseLibraryScreen(library: LibraryService, onChosen: () -> Unit, onSignOut: () -> Unit) {
    val scope = rememberCoroutineScope()
    var choices by remember { mutableStateOf<List<LibraryService.ChannelChoice>?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var attempt by remember { mutableIntStateOf(0) }

    fun choose(id: Long) = scope.launch {
        try { library.useExisting(id); onChosen() } catch (e: Exception) { error = e.sentence() }
    }

    LaunchedEffect(attempt) {
        error = null
        try {
            val found = library.candidateChannels()
            choices = found
            // One encrypted library and nothing to decide: open it, as iOS does.
            found.filter { it.isLibrary && it.encrypted }.singleOrNull()?.let { if (found.count { c -> c.isLibrary } == 1) choose(it.id) }
        } catch (e: Exception) {
            error = "Couldn't check your channels. ${e.sentence()}"
        }
    }

    Scaffold(topBar = { TopAppBar(title = { Text("Your library") }) }) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            val list = choices
            when {
                list == null && error == null -> Column(
                    Modifier.align(Alignment.Center),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    CircularProgressIndicator()
                    Text("Looking for your library…")
                }
                else -> LazyColumn(Modifier.fillMaxSize()) {
                    error?.let { e ->
                        item {
                            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                Text(e, color = MaterialTheme.colorScheme.error)
                                TextButton(onClick = { attempt++ }) { Text("Try again") }
                            }
                        }
                    }
                    val libraries = list.orEmpty().filter { it.isLibrary }
                    if (list != null && libraries.isEmpty()) item {
                        Text(
                            "No Lelvo library was found in this Telegram account. Set one up in Lelvo on iPhone or Mac, " +
                                "or sign in with the account that has it.",
                            Modifier.padding(16.dp),
                        )
                    }
                    items(libraries, key = { it.id }) { c ->
                        ListItem(
                            headlineContent = { Text(c.title) },
                            supportingContent = { Text(if (c.encrypted) "End-to-end encrypted" else "Not encrypted") },
                            modifier = Modifier.clickable { choose(c.id) },
                        )
                    }
                    item { TextButton(onClick = onSignOut, Modifier.padding(8.dp)) { Text("Use a different Telegram account") } }
                }
            }
        }
    }
}

/** Unlocks an encrypted library with its passphrase or recovery key. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun UnlockScreen(library: LibraryService, onUnlocked: () -> Unit, onOtherLibrary: () -> Unit) {
    val scope = rememberCoroutineScope()
    var secret by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    val submit = {
        if (secret.isNotBlank() && !busy) scope.launch {
            busy = true; error = null
            try { library.unlock(secret); onUnlocked() } catch (e: Exception) { error = e.sentence() } finally { busy = false }
        }
    }

    Scaffold(topBar = { TopAppBar(title = { Text("Unlock your library") }) }) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).imePadding().padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text("This library is end-to-end encrypted. Enter your passphrase to unlock it.", style = MaterialTheme.typography.bodyLarge)
            OutlinedTextField(
                value = secret, onValueChange = { secret = it },
                label = { Text("Passphrase or recovery key") },
                singleLine = true, isError = error != null, enabled = !busy,
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { submit() }),
                modifier = Modifier.fillMaxWidth().semantics { contentType = ContentType.Password },
            )
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            Button(onClick = { submit() }, enabled = secret.isNotBlank() && !busy, modifier = Modifier.fillMaxWidth()) {
                Text(if (busy) "Unlocking…" else "Unlock")
            }
            TextButton(onClick = onOtherLibrary) { Text("Choose another library") }
        }
    }
}
