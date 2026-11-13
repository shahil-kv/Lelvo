package app.lelvo.core.sync

import app.lelvo.core.format.MetaLog
import app.lelvo.core.format.TrashLog
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class KeptChoicesTest {
    @Test fun roundTrips() {
        val c = KeptChoices(
            offBackup = listOf("l:12", "h:abc|def"),
            waiting = mapOf(TrashLog.Op.DELETE to listOf("a", "b"), TrashLog.Op.RECOVER to listOf("c")),
            meta = mapOf("a" to mapOf(MetaLog.Key.Favorite to true, MetaLog.Key.Album("Goa Trip") to false)),
        )
        assertEquals(c, KeptChoices.decode(c.encode()))
    }

    @Test fun leavesOutWhatItDoesntKnow() {
        val c = KeptChoices.decode("""{"offBackup":["l:1"],"waiting":{"gone":["x"],"later":["y"],"del":["z"]},"meta":{"a":{"fav":true,"zz":true},"b":{"q":false}}}""")!!
        assertEquals(mapOf(TrashLog.Op.DELETE to listOf("z")), c.waiting)
        assertEquals(mapOf("a" to mapOf<MetaLog.Key, Boolean>(MetaLog.Key.Favorite to true)), c.meta)
        assertNull(KeptChoices.decode("not json"))
        assertTrue(KeptChoices().isEmpty)
    }
}
