package app.lelvo.core.video

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

// Mirrors VideoNavigationTests and VideoQualityTests in Packages/LelvoCore/Tests.
class VideoTest {
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
}
