package app.lelvo.core.cache

import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class DiskCacheTest {
    private val dir = Files.createTempDirectory("cache").toFile()

    @Test fun storesAndFinds() {
        val cache = DiskCache(dir) { 1000 }
        cache.put("t_abc", "jpg", ByteArray(10) { 1 })
        assertEquals(10, cache.get("t_abc", "jpg")?.length())
        assertNull(cache.get("t_other", "jpg"))
    }

    @Test fun dropsTheLeastRecentlyUsedFirst() {
        val cache = DiskCache(dir) { 250 }
        val a = cache.put("a", "bin", ByteArray(100)); a.setLastModified(1_000)
        val b = cache.put("b", "bin", ByteArray(100)); b.setLastModified(2_000)
        cache.get("a", "bin") // a is now the newest
        cache.put("c", "bin", ByteArray(100))
        assertNotNull(cache.get("a", "bin"))
        assertNull(cache.get("b", "bin"))
        assertNotNull(cache.get("c", "bin"))
    }

    @Test fun keepsAFileBiggerThanTheCapacity() {
        val cache = DiskCache(dir) { 50 }
        cache.put("big", "bin", ByteArray(100))
        assertNotNull(cache.get("big", "bin"))
    }

    @Test fun keysBecomeSafeFileNames() {
        val cache = DiskCache(dir) { 1000 }
        cache.put("o_x/../y", "jpg", ByteArray(1))
        assertEquals(dir, cache.get("o_x/../y", "jpg")?.parentFile)
    }
}
