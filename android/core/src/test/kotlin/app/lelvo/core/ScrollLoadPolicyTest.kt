package app.lelvo.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ScrollLoadPolicyTest {
    @Test fun slowScrollLoads() {
        val p = ScrollLoadPolicy()
        assertFalse(p.shouldDefer(0.0))
        assertFalse(p.shouldDefer(2999.9))
    }

    @Test fun thresholdDefers() {
        val p = ScrollLoadPolicy()
        assertTrue(p.shouldDefer(3000.0))
    }

    @Test fun hysteresisHoldsBetweenThresholds() {
        val p = ScrollLoadPolicy()
        assertTrue(p.shouldDefer(4000.0))
        assertTrue(p.shouldDefer(2500.0))
        assertTrue(p.shouldDefer(1800.0))
        assertFalse(p.shouldDefer(1799.9))
        assertFalse(p.shouldDefer(2500.0))
        assertTrue(p.shouldDefer(3000.0))
    }

    @Test fun negativeSpeedIsDirectionOnly() {
        val p = ScrollLoadPolicy()
        assertTrue(p.shouldDefer(-5000.0))
        assertFalse(p.shouldDefer(-100.0))
    }

    @Test fun nanAndInfinity() {
        val p = ScrollLoadPolicy()
        assertTrue(p.shouldDefer(Double.POSITIVE_INFINITY))
        assertFalse(p.shouldDefer(Double.NaN))
        assertTrue(p.shouldDefer(Double.NEGATIVE_INFINITY))
    }

    @Test fun resetClears() {
        val p = ScrollLoadPolicy()
        p.shouldDefer(9000.0)
        p.reset()
        assertFalse(p.shouldDefer(2500.0))
    }

    @Test fun prefetchCounts() {
        assertEquals(2, ScrollLoadPolicy.prefetchCount(0.0))
        assertEquals(2, ScrollLoadPolicy.prefetchCount(1799.9))
        assertEquals(1, ScrollLoadPolicy.prefetchCount(1800.0))
        assertEquals(1, ScrollLoadPolicy.prefetchCount(2999.9))
        assertEquals(0, ScrollLoadPolicy.prefetchCount(3000.0))
        assertEquals(0, ScrollLoadPolicy.prefetchCount(-9000.0))
        assertEquals(2, ScrollLoadPolicy.prefetchCount(Double.NaN))
        assertEquals(0, ScrollLoadPolicy.prefetchCount(Double.POSITIVE_INFINITY))
    }
}
