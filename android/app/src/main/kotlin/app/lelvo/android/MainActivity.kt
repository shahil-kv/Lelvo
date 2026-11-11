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
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import app.lelvo.android.signin.SignInScreen
import app.lelvo.android.ui.theme.LelvoTheme
import app.lelvo.telegram.AuthStep
import app.lelvo.telegram.TdClient
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val td = (application as LelvoApp).telegram
        setContent {
            LelvoTheme {
                val step by td.auth.collectAsState()
                if (step == AuthStep.Ready) SignedIn(td) else SignInScreen(td, step)
            }
        }
    }
}

/** Placeholder until Step 6 finds and unlocks the library. */
@Composable
private fun SignedIn(td: TdClient) {
    val scope = rememberCoroutineScope()
    Scaffold { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text("Signed in to Telegram", style = MaterialTheme.typography.headlineSmall)
            OutlinedButton(onClick = { scope.launch { td.logOut() } }) { Text("Sign out") }
        }
    }
}
