package app.lelvo.android.background

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/** WorkManager throws if an expedited request asks for battery or charging. Build both shapes here, not on a phone. */
class AutoRunRequestTest {
    @Test fun expeditedRequestBuildsWithNetworkOnly() {
        val request = BackupScheduler.autoRunRequest(wifiOnly = true, chargingOnly = false, delayMs = 0)
        assertTrue(request.workSpec.expedited)
        assertFalse(request.workSpec.constraints.requiresBatteryNotLow())
        assertFalse(request.workSpec.constraints.requiresCharging())
        assertEquals(BackupScheduler.AUTO_RUN, request.workSpec.input.getString(BackupWorker.KIND))
    }

    @Test fun delayedRequestKeepsBatteryNotLow() {
        val request = BackupScheduler.autoRunRequest(wifiOnly = false, chargingOnly = false, delayMs = 15 * 60_000L)
        assertFalse(request.workSpec.expedited)
        assertTrue(request.workSpec.constraints.requiresBatteryNotLow())
        assertFalse(request.workSpec.constraints.requiresCharging())
        assertEquals(15 * 60_000L, request.workSpec.initialDelay)
    }

    @Test fun chargingRequestIsNotExpedited() {
        val request = BackupScheduler.autoRunRequest(wifiOnly = true, chargingOnly = true, delayMs = 0)
        assertFalse(request.workSpec.expedited)
        assertTrue(request.workSpec.constraints.requiresCharging())
        assertTrue(request.workSpec.constraints.requiresBatteryNotLow())
    }
}
