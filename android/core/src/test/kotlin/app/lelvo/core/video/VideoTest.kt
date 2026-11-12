package app.lelvo.core.video

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

// Mirrors VideoNavigationTests and VideoQualityTests in Packages/LelvoCore/Tests.
class VideoTest {
    @Test fun stripTimesSitInTheMiddleOfEachSlice() {
        assertEquals(listOf(1.0, 3.0, 5.0, 7.0), VideoNavigation.stripTimes(8.0, 4))
        assertEquals(emptyList(), VideoNavigation.stripTimes(0.0, 8))
        assertEquals(emptyList(), VideoNavigation.stripTimes(Double.NaN, 8))
    }

    @Test fun skipStaysInsideTheVideo() {
        assertEquals(0.0, VideoNavigation.skipTarget(5.0, 100.0, -10.0))
        assertEquals(100.0, VideoNavigation.skipTarget(95.0, 100.0, 10.0))
        assertEquals(60.0, VideoNavigation.skipTarget(50.0, 100.0, 10.0))
    }

    @Test fun onlyLongVideosResumeAndNeverAtTheEdges() {
        assertEquals(300.0, VideoNavigation.resumePosition(300.0, 1200.0))
        assertNull(VideoNavigation.resumePosition(30.0, 60.0))
        assertNull(VideoNavigation.resumePosition(5.0, 1200.0))
        assertNull(VideoNavigation.resumePosition(1150.0, 1200.0))
        assertNull(VideoNavigation.resumePosition(null, 1200.0))
    }

    @Test fun noFastVersionOrOriginalSettingAlwaysPlaysOriginal() {
        assertEquals(VideoVersion.Original, VideoQualityPolicy.initial(VideoPreference.Automatic, hasFast = false))
        assertEquals(VideoVersion.Original, VideoQualityPolicy.initial(VideoPreference.Original, hasFast = true))
    }

    @Test fun automaticAndFastStartOnTheFastVersion() {
        assertEquals(VideoVersion.Fast, VideoQualityPolicy.initial(VideoPreference.Automatic, hasFast = true))
        assertEquals(VideoVersion.Fast, VideoQualityPolicy.initial(VideoPreference.Fast, hasFast = true))
    }

    @Test fun stallFallbackRespectsTheUser() {
        assertTrue(VideoQualityPolicy.fallsBackOnStall(VideoVersion.Original, VideoPreference.Automatic, hasFast = true, userChose = false))
        assertFalse(VideoQualityPolicy.fallsBackOnStall(VideoVersion.Original, VideoPreference.Automatic, hasFast = true, userChose = true))
        assertFalse(VideoQualityPolicy.fallsBackOnStall(VideoVersion.Original, VideoPreference.Original, hasFast = true, userChose = false))
        assertFalse(VideoQualityPolicy.fallsBackOnStall(VideoVersion.Original, VideoPreference.Automatic, hasFast = false, userChose = false))
    }

    @Test fun resolutionLabels() {
        assertEquals("4K", VideoLabels.resolution(3840, 2160, VideoVersion.Original))
        assertEquals("1080p", VideoLabels.resolution(3840, 2160, VideoVersion.Fast))
        assertEquals("1080p", VideoLabels.resolution(1080, 1920, VideoVersion.Original))
        assertEquals("1080p", VideoLabels.resolution(1080, 1920, VideoVersion.Fast))
        assertEquals("720p", VideoLabels.resolution(1280, 720, VideoVersion.Fast))
        assertNull(VideoLabels.resolution(0, 0, VideoVersion.Original))
    }

    @Test fun fastVersionNeedsAllItsParts() {
        fun item(have: Int, expected: Int?) = app.lelvo.core.index.LibraryItem(
            id = "v", localId = null, sha256 = "h", filename = "v.mov", kind = app.lelvo.core.index.ItemKind.Video, createdAt = 1,
            fileSize = 1, status = app.lelvo.core.index.ItemStatus.BackedUp,
            parts = mapOf("sp" to List(have) { app.lelvo.core.index.RemoteFile(it.toLong(), "f", "u", 1) }),
            expectedParts = expected?.let { mapOf("sp" to it) } ?: emptyMap(),
        )
        assertFalse(item(0, null).hasFastVersion)
        assertTrue(item(1, null).hasFastVersion)
        assertFalse(item(1, 2).hasFastVersion)
        assertTrue(item(2, 2).hasFastVersion)
    }

    @Test fun timesAndSpeeds() {
        assertEquals("0:05", VideoLabels.time(5.9))
        assertEquals("12:34", VideoLabels.time(754.0))
        assertEquals("1:02:03", VideoLabels.time(3723.0))
        assertEquals("0:00", VideoLabels.time(Double.NaN))
        assertEquals("Normal", VideoLabels.speed(1f))
        assertEquals("2×", VideoLabels.speed(2f))
        assertEquals("1.25×", VideoLabels.speed(1.25f))
        assertEquals("0.5×", VideoLabels.speed(0.5f))
    }

    @Test fun anOriginalThePhoneCantPlayNeverStarts() {
        assertEquals(VideoVersion.Fast, VideoQualityPolicy.initial(VideoPreference.Original, hasFast = true, originalPlayable = false))
        assertEquals(VideoVersion.Original, VideoQualityPolicy.initial(VideoPreference.Original, hasFast = false, originalPlayable = false))
        assertEquals(VideoVersion.Original, VideoQualityPolicy.initial(VideoPreference.Original, hasFast = true, originalPlayable = true))
    }
}

class StreamingCopyPolicyTest {
    private fun video(size: Long, seconds: Double?, w: Int = 1920, h: Int = 1080) = app.lelvo.core.index.LibraryItem(
        "v", "1", "h", "v.mp4", app.lelvo.core.index.ItemKind.Video, 0, width = w, height = h, duration = seconds,
        fileSize = size, status = app.lelvo.core.index.ItemStatus.BackedUp,
    )

    @Test fun onlyBigOrSharpVideos() {
        // 8 Mbit/s 1080p: worth a copy.
        kotlin.test.assertTrue(StreamingCopyPolicy.shouldMake(video(10_000_000, 10.0)))
        // 3.2 Mbit/s 1080p: streams fine as it is.
        kotlin.test.assertFalse(StreamingCopyPolicy.shouldMake(video(40_000_000, 100.0)))
        // Same bitrate but 4K: a copy.
        kotlin.test.assertTrue(StreamingCopyPolicy.shouldMake(video(40_000_000, 100.0, 3840, 2160)))
        // Small, no duration, already skipped or already there: no.
        kotlin.test.assertFalse(StreamingCopyPolicy.shouldMake(video(3_000_000, 1.0)))
        kotlin.test.assertFalse(StreamingCopyPolicy.shouldMake(video(10_000_000, null)))
        kotlin.test.assertFalse(StreamingCopyPolicy.shouldMake(video(10_000_000, 10.0).copy(streamingCopySkipped = true)))
        kotlin.test.assertFalse(StreamingCopyPolicy.shouldMake(video(10_000_000, 10.0).withParts("sp", listOf(app.lelvo.core.index.RemoteFile(1, "f", "u", 5)), 1)))
    }

    @Test fun keptOnlyWhenMuchSmaller() {
        kotlin.test.assertTrue(StreamingCopyPolicy.isWorthKeeping(69, 100))
        kotlin.test.assertFalse(StreamingCopyPolicy.isWorthKeeping(70, 100))
        kotlin.test.assertFalse(StreamingCopyPolicy.isWorthKeeping(0, 100))
        kotlin.test.assertEquals(3_000_000, StreamingCopyPolicy.targetBitsPerSecond(60f))
        kotlin.test.assertEquals(2_000_000, StreamingCopyPolicy.targetBitsPerSecond(30f))
    }
}
