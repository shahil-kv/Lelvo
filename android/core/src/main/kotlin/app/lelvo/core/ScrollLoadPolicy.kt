package app.lelvo.core

import kotlin.math.abs

/**
 * When a photo grid should stop starting thumbnail loads, and how far ahead it should prefetch. Pure, so iPhone and
 * Android share the same numbers (the Swift twin uses identical names and thresholds). Speeds are in dp (points) per
 * second; the sign is the scroll direction and is ignored.
 *
 * - Above [DEFER_ABOVE] the tiles flying past are off screen before their load finishes: show the placeholder.
 * - Loads resume once the speed falls below [RESUME_BELOW]. Between the two the previous answer stands (hysteresis),
 *   so a fling that hovers around one number does not flicker.
 */
class ScrollLoadPolicy {
    private var deferring = false

    /** True while new thumbnail loads should wait. Stateful: remembers the last answer for the hysteresis band. */
    fun shouldDefer(speedDpPerSecond: Double): Boolean {
        val speed = normalized(speedDpPerSecond)
        deferring = when {
            speed >= DEFER_ABOVE -> true
            speed < RESUME_BELOW -> false
            else -> deferring
        }
        return deferring
    }

    /** Back to "loading"; call when scrolling stops or the grid is rebuilt. */
    fun reset() { deferring = false }

    companion object {
        /** Start deferring at or above this speed. */
        const val DEFER_ABOVE = 3000.0

        /** Stop deferring below this speed. */
        const val RESUME_BELOW = 1800.0

        /** Screens of tiles prefetched ahead while scrolling slowly. */
        const val MAX_PREFETCH_SCREENS = 2

        /**
         * How many screens ahead of the scroll direction to prefetch: [MAX_PREFETCH_SCREENS] when slow, 1 while
         * speeding up (between [RESUME_BELOW] and [DEFER_ABOVE]), 0 when flinging. Stateless.
         */
        fun prefetchCount(speedDpPerSecond: Double): Int {
            val speed = normalized(speedDpPerSecond)
            return when {
                speed >= DEFER_ABOVE -> 0
                speed >= RESUME_BELOW -> 1
                else -> MAX_PREFETCH_SCREENS
            }
        }

        /** NaN counts as standing still; negative speed is the same as positive; infinity is a very fast fling. */
        private fun normalized(speed: Double): Double = if (speed.isNaN()) 0.0 else abs(speed)
    }
}
