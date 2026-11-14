package app.lelvo.core.backup

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import java.time.ZoneOffset
import java.time.ZonedDateTime

class BackgroundRunsTest {
    private val now = 1_800_000_000_000L
    private val day = 86_400_000L

    private fun run(source: RunSource, daysAgo: Double = 0.0, uploaded: Int = 0) = RunRecord(
        source, now - (daysAgo * day).toLong(), 5.0, uploaded, 0,
    )

    @Test fun keepsTheNewestRecords() {
        var list = emptyList<RunRecord>()
        for (i in 0 until 5) list = BackgroundRuns.appending(run(RunSource.App, uploaded = i), list, limit = 3)
        assertEquals(listOf(2, 3, 4), list.map { it.uploaded })
    }

    @Test fun keepsTwoHundred() {
        var list = emptyList<RunRecord>()
        for (i in 0 until 250) list = BackgroundRuns.appending(run(RunSource.App, uploaded = i), list)
        assertEquals(200, list.size)
        assertEquals(50, list.first().uploaded)
        assertEquals(249, list.last().uploaded)
    }

    @Test fun nextRunStopsWhenNothingIsLeftOrARuleBlocksIt() {
        assertNull(BackgroundRuns.nextAutoRun(0, stoppedByTime = true, blocked = false, floodUntil = 0, now = now))
        assertNull(BackgroundRuns.nextAutoRun(4, stoppedByTime = true, blocked = true, floodUntil = 0, now = now))
    }

    @Test fun floodWaitLaterThanTheGapWins() {
        val gap = BackgroundRuns.nextAutoRun(3, stoppedByTime = true, blocked = false, floodUntil = 0, now = now)
        assertEquals(now + 15 * 60_000L, gap)
        val flood = now + 20 * 60_000L
        val later = BackgroundRuns.nextAutoRun(3, stoppedByTime = false, blocked = false, floodUntil = flood, now = now)
        assertEquals(flood, later)
    }

    @Test fun mayTakeNextItemRespectsTheDeadline() {
        assertTrue(BackgroundRuns.mayTakeNextItem(null, now))
        assertTrue(BackgroundRuns.mayTakeNextItem(now + 1, now))
        assertFalse(BackgroundRuns.mayTakeNextItem(now, now))
        assertFalse(BackgroundRuns.mayTakeNextItem(now - 1, now))
    }

    @Test fun emptyRunsResetWhenAPartWasSavedOrTheUserRan() {
        assertEquals(0, BackgroundRuns.emptyRunsAfter(2, uploaded = 0, partsSaved = 1, userRun = false))
        assertEquals(0, BackgroundRuns.emptyRunsAfter(2, uploaded = 1, partsSaved = 0, userRun = false))
        assertEquals(0, BackgroundRuns.emptyRunsAfter(2, uploaded = 0, partsSaved = 0, userRun = true))
        assertEquals(3, BackgroundRuns.emptyRunsAfter(2, uploaded = 0, partsSaved = 0, userRun = false))
    }

    @Test fun laterDeadlineNeverMovesEarlier() {
        assertEquals(500L, BackgroundRuns.laterDeadline(500, 100))
        assertEquals(800L, BackgroundRuns.laterDeadline(100, 800))
    }

    @Test fun reminderBacksOffTwoFourEightEight() {
        fun days(sent: Int) = (BackgroundRuns.nextReminder(now, 5, sent, now)!! - now) / day
        assertEquals(2, days(0))
        assertEquals(6, days(1))
        assertEquals(14, days(2))
        assertEquals(22, days(3))
    }

    @Test fun noReminderWhenNothingWaits() {
        assertNull(BackgroundRuns.nextReminder(now, 0, 0, now))
    }

    @Test fun reminderWithoutAnyUploadCountsFromNow() {
        assertEquals(now + 2 * day, BackgroundRuns.nextReminder(null, 3, 0, now))
    }

    @Test fun overnightEdges() {
        val zone = ZoneOffset.UTC
        fun at(hour: Int, minute: Int) = ZonedDateTime.of(2026, 11, 14, hour, minute, 0, 0, zone).toInstant().toEpochMilli()
        assertFalse(BackgroundRuns.isOvernight(at(21, 59), zone))
        assertTrue(BackgroundRuns.isOvernight(at(22, 0), zone))
        assertTrue(BackgroundRuns.isOvernight(at(6, 59), zone))
        assertFalse(BackgroundRuns.isOvernight(at(7, 0), zone))
    }

    @Test fun summaryText() {
        assertEquals("312 photos and 4 videos backed up overnight.", BackgroundRuns.summaryText(312, 4, overnight = true))
        assertEquals("1 photo and 1 video backed up overnight.", BackgroundRuns.summaryText(1, 1, overnight = true))
        assertEquals("2 photos backed up.", BackgroundRuns.summaryText(2, 0, overnight = false))
        assertEquals("1 photo backed up.", BackgroundRuns.summaryText(1, 0, overnight = false))
        assertEquals("3 videos backed up overnight.", BackgroundRuns.summaryText(0, 3, overnight = true))
        assertEquals("2 videos backed up.", BackgroundRuns.summaryText(0, 2, overnight = false))
        assertNull(BackgroundRuns.summaryText(0, 0, overnight = true))
    }

    @Test fun recordsRoundTripAndDropADamagedOne() {
        val list = listOf(RunRecord(RunSource.AutoRun, now, 9.5, 3, 10, "out of time"))
        assertEquals(list, BackgroundRuns.decode(BackgroundRuns.encode(list)))
        assertEquals(emptyList<RunRecord>(), BackgroundRuns.decode("not json"))
        assertEquals(emptyList<RunRecord>(), BackgroundRuns.decode(null))
    }

    @Test fun backgroundIssueOrder() {
        fun issue(
            partial: Boolean = false, restricted: Boolean = false, optimized: Boolean = false,
            bucket: Int = BackgroundRuns.STANDBY_ACTIVE, force: Boolean = false,
            last: Long? = now, waiting: Int = 0,
        ) = BackgroundRuns.backgroundIssue(partial, restricted, optimized, bucket, force, last, waiting, now)

        assertEquals(BackgroundIssue.None, issue())
        assertEquals(BackgroundIssue.PartialPhotoAccess, issue(partial = true, restricted = true))
        assertEquals(BackgroundIssue.BackgroundRestricted, issue(restricted = true, force = true))
        assertEquals(BackgroundIssue.ForceStopped, issue(force = true, optimized = true, waiting = 5, last = now - 2 * day))
        assertEquals(BackgroundIssue.None, issue(optimized = true, waiting = 5, last = now))
        assertEquals(BackgroundIssue.BatteryOptimized, issue(optimized = true, waiting = 5, last = now - 2 * day))
        assertEquals(BackgroundIssue.RareBucket, issue(bucket = BackgroundRuns.STANDBY_RARE, optimized = true, waiting = 5, last = now - 2 * day))
        assertEquals(BackgroundIssue.None, issue(bucket = BackgroundRuns.STANDBY_RARE, waiting = 0))
    }

    @Test fun immediateRunIsExpeditedWithoutBatteryConstraints() {
        val plan = BackgroundRuns.autoRunPlan(wifiOnly = true, chargingOnly = false, delayMs = 0)
        assertTrue(plan.expedited)
        assertEquals(0L, plan.delayMs)
        assertTrue(plan.unmetered)
        assertFalse(plan.batteryNotLow)
        assertFalse(plan.requiresCharging)
    }

    @Test fun aDelayedOrChargingRunKeepsBatteryConstraints() {
        val delayed = BackgroundRuns.autoRunPlan(wifiOnly = false, chargingOnly = false, delayMs = 15 * 60_000L)
        assertFalse(delayed.expedited)
        assertTrue(delayed.batteryNotLow)
        assertFalse(delayed.requiresCharging)
        assertEquals(15 * 60_000L, delayed.delayMs)

        val charging = BackgroundRuns.autoRunPlan(wifiOnly = true, chargingOnly = true, delayMs = 0)
        assertFalse(charging.expedited)
        assertTrue(charging.batteryNotLow)
        assertTrue(charging.requiresCharging)
    }
}
