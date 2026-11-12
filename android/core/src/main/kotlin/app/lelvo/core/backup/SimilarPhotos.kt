package app.lelvo.core.backup

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sqrt

/**
 * Grouping near-identical photos (bursts, several shots of the same thing) for Duplicates review (iOS `SimilarPhotos`).
 * Comparing pictures is the slow part, so only photos taken close together in time are compared at all, and only with
 * each other.
 */
object SimilarPhotos {
    /** Photos further apart than this (ms) start a new run of candidates. */
    const val MAX_GAP_MS = 60_000L
    /** Runs longer than this are split, so one long shoot doesn't compare hundreds of photos with each other. */
    const val MAX_RUN = 40

    /** [date] epoch ms. */
    data class Candidate(val id: String, val date: Long, val pixels: Long, val favorite: Boolean)

    /** Runs of at least two photos, each taken within [MAX_GAP_MS] of the one before, oldest first. */
    fun runs(candidates: List<Candidate>): List<List<Candidate>> {
        val out = ArrayList<List<Candidate>>()
        var run = ArrayList<Candidate>()
        fun close() {
            if (run.size > 1) out += run.chunked(MAX_RUN).filter { it.size > 1 }
            run = ArrayList()
        }
        for (c in candidates.sortedBy { it.date }) {
            val last = run.lastOrNull()
            if (last != null && c.date - last.date > MAX_GAP_MS) close()
            run += c
        }
        close()
        return out
    }

    /** Groups of a run whose photos are linked by [close] pairs (false when two can't be compared). */
    fun groups(run: List<Candidate>, close: (Candidate, Candidate) -> Boolean): List<List<Candidate>> {
        val parent = IntArray(run.size) { it }
        fun root(start: Int): Int {
            var i = start
            while (parent[i] != i) { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        for (i in run.indices) for (j in i + 1 until run.size) {
            if (close(run[i], run[j])) parent[root(j)] = root(i)
        }
        return run.indices.groupBy(::root).values
            .filter { it.size > 1 }
            .map { g -> g.sorted().map { run[it] } }
            .sortedBy { it[0].date }
    }

    /** The photo to suggest keeping: a favourite, else the largest, else the first taken. */
    fun best(group: List<Candidate>): Candidate? = group.minWithOrNull(
        compareBy<Candidate> { !it.favorite }.thenByDescending { it.pixels }.thenBy { it.date },
    )
}

/**
 * A 64-bit perceptual hash (DCT of a 32×32 grey image, the low 8×8 frequencies against their median). iOS compares
 * Vision feature prints; Android has no built-in equivalent and a model would be a new dependency, so near-identical
 * shots are found by how close their hashes are. It reacts to the picture's layout, not to small exposure or JPEG
 * changes, which is what bursts differ by.
 */
object PerceptualHash {
    const val SIDE = 32
    /** Hashes this many bits apart or fewer count as the same shot. */
    const val MAX_BITS = 10

    private val cosTable = Array(8) { u -> DoubleArray(SIDE) { x -> cos((2 * x + 1) * u * PI / (2 * SIDE)) } }

    /** [grey]: SIDE×SIDE luminance values, row by row. */
    fun of(grey: IntArray): Long {
        require(grey.size == SIDE * SIDE)
        // Only the lowest 8×8 frequencies are needed: rows first, then columns.
        val rows = Array(SIDE) { y -> DoubleArray(8) { u -> var s = 0.0; for (x in 0 until SIDE) s += grey[y * SIDE + x] * cosTable[u][x]; s } }
        val coeffs = DoubleArray(64)
        for (v in 0 until 8) for (u in 0 until 8) {
            var s = 0.0
            for (y in 0 until SIDE) s += rows[y][u] * cosTable[v][y]
            coeffs[v * 8 + u] = s * (if (u == 0) sqrt(0.5) else 1.0) * (if (v == 0) sqrt(0.5) else 1.0)
        }
        // The first coefficient is the overall brightness: left out of the median so a brighter shot hashes the same.
        val median = coeffs.copyOfRange(1, 64).sorted().let { (it[31] + it[32]) / 2 }
        var hash = 0L
        for (i in 0 until 64) if (coeffs[i] > median) hash = hash or (1L shl i)
        return hash
    }

    fun distance(a: Long, b: Long): Int = java.lang.Long.bitCount(a xor b)

    fun close(a: Long, b: Long): Boolean = distance(a, b) <= MAX_BITS
}
