package app.lelvo.core

import app.lelvo.core.format.LibraryNames
import kotlin.test.Test
import kotlin.test.assertEquals

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
}
