import Foundation
import Testing
import LelvoCore

@Suite struct VideoNavigationTests {
    @Test func skipStaysInsideTheVideo() {
        #expect(VideoNavigation.skipTarget(current: 30, duration: 100, by: 10) == 40)
        #expect(VideoNavigation.skipTarget(current: 5, duration: 100, by: -10) == 0)
        #expect(VideoNavigation.skipTarget(current: 95, duration: 100, by: 10) == 100)
        #expect(VideoNavigation.skipTarget(current: .nan, duration: 100, by: 10) == 10)
        #expect(VideoNavigation.skipTarget(current: 3, duration: .nan, by: -10) == 0)
    }

    @Test func stripFramesAreEvenlySpaced() {
        #expect(VideoNavigation.stripTimes(duration: 80, count: 4) == [10, 30, 50, 70])
        #expect(VideoNavigation.stripTimes(duration: 0, count: 8).isEmpty)
        #expect(VideoNavigation.stripTimes(duration: .infinity, count: 8).isEmpty)
    }

    @Test func onlyLongVideosResumeAndNeverAtTheEdges() {
        #expect(VideoNavigation.resumePosition(saved: 300, duration: 1200) == 300)
        // Short clips always start from the beginning.
        #expect(VideoNavigation.resumePosition(saved: 30, duration: 60) == nil)
        // The first seconds, the last 5 % (or 10 s), and nothing saved.
        #expect(VideoNavigation.resumePosition(saved: 5, duration: 1200) == nil)
        #expect(VideoNavigation.resumePosition(saved: 1150, duration: 1200) == nil)
        #expect(VideoNavigation.resumePosition(saved: 125, duration: 130) == nil)
        #expect(VideoNavigation.resumePosition(saved: nil, duration: 1200) == nil)
        #expect(VideoNavigation.shouldRemember(position: 600, duration: 1200))
        #expect(!VideoNavigation.shouldRemember(position: 1199, duration: 1200))
    }
}
