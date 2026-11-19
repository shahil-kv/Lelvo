package app.lelvo.core.support

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** iOS `FileNamesTests`. */
class FileNamesTest {
    @Test fun longNamesFitWithTheirExtension() {
        val long = "D13-" + "long".repeat(56) + ".jpg"
        val safe = FileNames.safe(long)
        assertTrue(safe.toByteArray().size <= FileNames.MAX_BYTES)
        assertTrue(safe.endsWith(".jpg"))
        assertTrue(safe.startsWith("D13-long"))
        assertEquals("IMG_0001.HEIC", FileNames.safe("IMG_0001.HEIC"))
        assertEquals("a_b_c.jpg", FileNames.safe("a/b:c.jpg"))
        assertEquals("file", FileNames.safe(""))
        val cut = FileNames.safe("😀".repeat(60) + ".png")
        assertTrue(cut.toByteArray().size <= FileNames.MAX_BYTES)
        assertTrue(cut.endsWith("😀.png"))
    }
}
