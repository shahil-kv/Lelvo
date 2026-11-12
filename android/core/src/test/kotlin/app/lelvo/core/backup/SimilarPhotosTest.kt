package app.lelvo.core.backup

import kotlin.math.sin
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class SimilarPhotosTest {
    private val t0 = 1_800_000_000_000L

    private fun c(id: String, seconds: Long, pixels: Long = 100, favorite: Boolean = false) =
        SimilarPhotos.Candidate(id, t0 + seconds * 1000, pixels, favorite)

    @Test fun runsSplitOnGapsAndDropSingles() {
        val runs = SimilarPhotos.runs(listOf(c("b", 30), c("a", 0), c("c", 200), c("d", 230), c("e", 1000)))
        assertEquals(listOf(listOf("a", "b"), listOf("c", "d")), runs.map { r -> r.map { it.id } })
    }

    @Test fun longRunsAreSplit() {
        val runs = SimilarPhotos.runs((0 until SimilarPhotos.MAX_RUN + 5).map { c("p$it", it.toLong()) })
        assertEquals(2, runs.size)
        assertEquals(SimilarPhotos.MAX_RUN, runs[0].size)
        assertEquals(5, runs[1].size)
    }

    @Test fun groupsFollowCloseDistancesTransitively() {
        // a~b, b~c are close; d is far from everything; e can't be compared.
        val run = listOf(c("a", 0), c("b", 1), c("c", 2), c("d", 3), c("e", 4))
        val close = setOf("ab", "bc")
        val groups = SimilarPhotos.groups(run) { x, y -> x.id != "e" && y.id != "e" && (x.id + y.id) in close }
        assertEquals(listOf(listOf("a", "b", "c")), groups.map { g -> g.map { it.id } })
    }

    @Test fun suggestsFavouriteThenLargestThenFirst() {
        assertEquals("b", SimilarPhotos.best(listOf(c("a", 0, pixels = 50), c("b", 1, pixels = 10, favorite = true)))?.id)
        assertEquals("b", SimilarPhotos.best(listOf(c("a", 0, pixels = 50), c("b", 1, pixels = 90)))?.id)
        assertEquals("a", SimilarPhotos.best(listOf(c("a", 0), c("b", 1)))?.id)
    }
}

class PerceptualHashTest {
    private val n = PerceptualHash.SIDE

    private fun image(f: (Int, Int) -> Double) = IntArray(n * n) { i -> f(i % n, i / n).coerceIn(0.0, 255.0).toInt() }

    // A textured scene with a bright blob, like a photo; a flat synthetic image has too little detail to hash steadily.
    private fun scene(dx: Int = 0, gain: Double = 1.0, offset: Double = 0.0, noise: Double = 0.0): IntArray {
        val random = java.util.Random(1)
        return image { x, y ->
            val bx = x - 12 - dx; val by = y - 14
            val texture = 20 * sin(x * 0.9 + y * 0.4) + 15 * kotlin.math.cos(y * 1.3)
            (50 + 2 * y + texture + 120.0 * kotlin.math.exp(-(bx * bx + by * by) / 40.0)) * gain + offset +
                (random.nextDouble() * 2 - 1) * noise
        }
    }

    @Test fun sameImageIsZeroApart() {
        assertEquals(0, PerceptualHash.distance(PerceptualHash.of(scene()), PerceptualHash.of(scene())))
    }

    @Test fun exposureNoiseAndSmallShiftsStayClose() {
        val base = PerceptualHash.of(scene())
        assertTrue(PerceptualHash.close(base, PerceptualHash.of(scene(gain = 0.85, offset = 10.0))))
        assertTrue(PerceptualHash.close(base, PerceptualHash.of(scene(dx = 1))))
        assertTrue(PerceptualHash.close(base, PerceptualHash.of(scene(noise = 8.0))))
    }

    @Test fun differentPicturesAreFarApart() {
        val base = PerceptualHash.of(scene())
        val stripes = PerceptualHash.of(image { x, _ -> 128 + 100 * sin(x / 2.0) })
        val other = PerceptualHash.of(image { x, y -> 255.0 - 6 * x - 2 * y })
        assertFalse(PerceptualHash.close(base, stripes))
        assertFalse(PerceptualHash.close(base, other))
    }
}
