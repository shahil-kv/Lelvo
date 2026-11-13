package app.lelvo.core

import app.lelvo.core.format.LibraryNames
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class LibraryNamesTest {
    @Test
    fun keepsTheBaseWhenFree() {
        assertEquals("Lelvo Library", LibraryNames.unused("Lelvo Library", listOf("Holidays")))
    }

    @Test
    fun countsUpPastTakenNamesIgnoringCaseAndSpaces() {
        assertEquals("Lelvo Library 2", LibraryNames.unused("Lelvo Library", listOf(" lelvo library ")))
        assertEquals("Lelvo Library 4", LibraryNames.unused("Lelvo Library", listOf("Lelvo Library", "LELVO LIBRARY 2", "Lelvo Library 3")))
    }

    @Test
    fun wrapsTheNameInTheWarningOnce() {
        assertEquals("🚨 Lelvo Library · Do not delete 🚨", LibraryNames.channelTitle("Lelvo Library"))
        assertEquals("🚨 Family · Do not delete 🚨", LibraryNames.channelTitle("  Family "))
        assertEquals("🚨 Family · Do not delete 🚨", LibraryNames.channelTitle("🚨 Family · Do not delete 🚨"))
    }

    @Test
    fun titleFitsTelegramsLimit() {
        assertTrue(LibraryNames.channelTitle("a".repeat(300)).length <= 128)
    }

    @Test
    fun plainNameDropsTheWarning() {
        assertEquals("Lelvo Library 2", LibraryNames.plain("🚨 Lelvo Library 2 · Do not delete 🚨"))
        assertEquals("Lelvo Library", LibraryNames.plain("Lelvo Library"))
        assertEquals("🚨 Holidays", LibraryNames.plain("🚨 Holidays"))
    }
}
