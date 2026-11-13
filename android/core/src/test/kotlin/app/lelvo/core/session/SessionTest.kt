package app.lelvo.core.session

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

// Mirrors SessionWatchTests and the flood-wait cases in Packages/LelvoCore/Tests.
class SessionTest {
    @Test fun aSessionRemovedElsewhereIsNoticed() {
        val w = SessionWatch(); w.ready(); w.loggingOut()
        assertTrue(w.closed())
    }

    @Test fun signingOutHereIsNot() {
        val w = SessionWatch(); w.ready(); w.ownSignOut(); w.loggingOut()
        assertFalse(w.closed())
    }

    @Test fun aRestartIsNot() {
        val w = SessionWatch(); w.ready()
        assertFalse(w.closed())
    }

    @Test fun aSignOutThatDidNothingDoesNotHideALaterRemoval() {
        val w = SessionWatch(); w.ownSignOut(); w.ready(); w.loggingOut()
        assertTrue(w.closed())
    }

    @Test fun itCountsOnlyOnce() {
        val w = SessionWatch(); w.loggingOut()
        assertTrue(w.closed())
        assertFalse(w.closed())
    }

    @Test fun floodWait() {
        assertEquals(42, TelegramErrors.floodWaitSeconds("FLOOD_WAIT_42"))
        assertEquals(7, TelegramErrors.floodWaitSeconds("FLOOD_PREMIUM_WAIT_7"))
        assertEquals(30, TelegramErrors.floodWaitSeconds("Too Many Requests: retry after 30"))
        assertNull(TelegramErrors.floodWaitSeconds("PHONE_CODE_INVALID"))
        assertEquals("Telegram asked us to slow down. Waiting 5 s.", TelegramErrors.friendly(429, "FLOOD_WAIT_5"))
    }
}
