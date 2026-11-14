import Foundation
import Testing
@testable import LelvoCore

@Suite struct BackgroundRunsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func run(_ s: RunSource, daysAgo: Double = 0, uploaded: Int = 0) -> RunRecord {
        RunRecord(source: s, startedAt: now.addingTimeInterval(-daysAgo * 86_400), seconds: 5, uploaded: uploaded, remaining: 0)
    }

    @Test func keepsTheNewestRecords() {
        var list: [RunRecord] = []
        for i in 0..<5 { list = BackgroundRuns.appending(run(.app, uploaded: i), to: list, limit: 3) }
        #expect(list.map(\.uploaded) == [2, 3, 4])
    }

    @Test func notSetUpWithoutShortcutRuns() {
        #expect(BackgroundRuns.automationHealth([run(.app), run(.refresh)], newestPhotoDate: now, now: now) == .notSetUp)
        #expect(BackgroundRuns.automationHealth([], newestPhotoDate: nil, now: now) == .notSetUp)
    }

    @Test func workingWhenRecent() {
        let r = run(.shortcut, daysAgo: 1)
        #expect(BackgroundRuns.automationHealth([r], newestPhotoDate: now, now: now) == .working(lastRun: r.startedAt))
    }

    @Test func noPhotoSinceLastRunCountsAsWorking() {
        let r = run(.shortcut, daysAgo: 30)
        let old = r.startedAt.addingTimeInterval(-60)
        #expect(BackgroundRuns.automationHealth([r], newestPhotoDate: old, now: now) == .working(lastRun: r.startedAt))
        #expect(BackgroundRuns.automationHealth([r], newestPhotoDate: nil, now: now) == .working(lastRun: r.startedAt))
    }

    @Test func seemsOffWhenPhotosWereTakenAfterAStaleRun() {
        let r = run(.shortcut, daysAgo: 10)
        #expect(BackgroundRuns.automationHealth([r], newestPhotoDate: now, now: now) == .seemsOff(lastRun: r.startedAt))
    }

    @Test func usesTheNewestShortcutRun() {
        let list = [run(.shortcut, daysAgo: 20), run(.shortcut, daysAgo: 1), run(.app)]
        #expect(BackgroundRuns.automationHealth(list, newestPhotoDate: now, now: now) == .working(lastRun: list[1].startedAt))
    }

    @Test func reminderBacksOffTwoFourEightEight() {
        let last = now
        func days(_ sent: Int) -> Double {
            BackgroundRuns.nextReminder(lastUpload: last, waiting: 5, remindersSent: sent, now: now)!.timeIntervalSince(last) / 86_400
        }
        #expect(days(0) == 2)
        #expect(days(1) == 6)
        #expect(days(2) == 14)
        #expect(days(3) == 22)
    }

    @Test func noReminderWhenNothingWaits() {
        #expect(BackgroundRuns.nextReminder(lastUpload: now, waiting: 0, remindersSent: 0, now: now) == nil)
    }

    @Test func reminderWithoutAnyUploadCountsFromNow() {
        #expect(BackgroundRuns.nextReminder(lastUpload: nil, waiting: 3, remindersSent: 0, now: now) == now.addingTimeInterval(2 * 86_400))
    }

    @Test func summaryText() {
        #expect(BackgroundRuns.summaryText(photos: 312, videos: 4, overnight: true) == "312 photos and 4 videos backed up overnight.")
        #expect(BackgroundRuns.summaryText(photos: 1, videos: 1, overnight: true) == "1 photo and 1 video backed up overnight.")
        #expect(BackgroundRuns.summaryText(photos: 2, videos: 0, overnight: false) == "2 photos backed up.")
        #expect(BackgroundRuns.summaryText(photos: 0, videos: 3, overnight: true) == "3 videos backed up overnight.")
        #expect(BackgroundRuns.summaryText(photos: 0, videos: 0, overnight: true) == nil)
    }

    @Test func overnightHours() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        func at(_ h: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: h))! }
        #expect(BackgroundRuns.isOvernight(at(23), calendar: cal))
        #expect(BackgroundRuns.isOvernight(at(3), calendar: cal))
        #expect(!BackgroundRuns.isOvernight(at(7), calendar: cal))
        #expect(!BackgroundRuns.isOvernight(at(15), calendar: cal))
        #expect(BackgroundRuns.isOvernight(at(22), calendar: cal))
    }
}
