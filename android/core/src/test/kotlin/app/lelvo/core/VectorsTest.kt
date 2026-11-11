package app.lelvo.core

import java.io.File
import kotlin.test.Test
import kotlin.test.assertTrue

class VectorsTest {
    @Test
    fun vectorsAreReachable() {
        val dir = File(System.getProperty("lelvo.vectors"))
        assertTrue(File(dir, "format1.json").isFile, "test vectors not found at $dir")
    }
}
