package app.lelvo.data

import android.content.Context
import android.content.SharedPreferences
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Lelvo Pro entitlement on Android. Play Billing wires in when the store listing is ready; until then Debug unlock
 * matches iOS `ProStore.debugUnlocked`.
 */
class ProStore(context: Context) {
    private val p: SharedPreferences =
        context.applicationContext.getSharedPreferences("pro", Context.MODE_PRIVATE)

    private val _isPro = MutableStateFlow(p.getBoolean(KEY_DEBUG, false))
    val isPro: StateFlow<Boolean> = _isPro.asStateFlow()

    var debugUnlocked: Boolean
        get() = p.getBoolean(KEY_DEBUG, false)
        set(v) {
            p.edit().putBoolean(KEY_DEBUG, v).apply()
            refresh()
        }

    fun refresh() {
        // Later: OR with Play Billing entitlement. Debug unlock is enough for building Pro features now.
        _isPro.value = debugUnlocked
    }

    companion object {
        private const val KEY_DEBUG = "proDebugUnlocked"
    }
}
