package app.lelvo.core.index

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** iOS `ExifDateTests.offsetAloneGivesTheCaptionZone`. */
class ExifOffsetTest {
    @Test fun offsetAloneGivesTheCaptionZone() {
        assertEquals(540, ExifOffset.minutes("+09:00"))
        assertEquals(-210, ExifOffset.minutes("-03:30"))
        assertEquals(330, ExifOffset.minutes("+0530"))
        assertNull(ExifOffset.minutes("   "))
        assertNull(ExifOffset.minutes(null))
    }
}
