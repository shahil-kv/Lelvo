package app.lelvo.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import app.lelvo.android.library.ChooseLibraryScreen
import app.lelvo.android.library.UnlockScreen
import app.lelvo.android.signin.SignInScreen
import app.lelvo.android.ui.theme.LelvoTheme
import app.lelvo.telegram.AuthStep
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val app = application as LelvoApp
        setContent {
            LelvoTheme {
                val step by app.telegram.auth.collectAsState()
                if (step == AuthStep.Ready) LibraryFlow(app) else SignInScreen(app.telegram, step)
            }
        }
    }
}

/** Signed in: choose the library, unlock it, then the app. */
@Composable
private fun LibraryFlow(app: LelvoApp) {
    val scope = rememberCoroutineScope()
    var changes by remember { mutableIntStateOf(0) }
    val signOut: () -> Unit = { scope.launch { app.library.forget(); app.telegram.logOut() } }
    changes.let {
        when {
            !app.library.isConfigured -> ChooseLibraryScreen(app.library, onChosen = { changes++ }, onSignOut = signOut)
            !app.library.isUnlocked -> UnlockScreen(app.library, onUnlocked = { changes++ }, onOtherLibrary = { app.library.forget(); changes++ })
            else -> Unlocked(onSignOut = signOut)
        }
    }
}

/** Placeholder until Steps 7–8 bring the timeline. */
@Composable
private fun Unlocked(onSignOut: () -> Unit) {
    Scaffold { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text("Your library is unlocked", style = MaterialTheme.typography.headlineSmall)
            OutlinedButton(onClick = onSignOut) { Text("Sign out") }
        }
    }
}
