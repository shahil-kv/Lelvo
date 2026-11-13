import Testing
import Foundation
@testable import LelvoCore

@Suite struct ExifDateTests {
    @Test func offsetShiftsTheInstantAndKeepsTheZone() throws {
        let parsed = try #require(ExifDate.parse("2019:07:04 18:22:01", offset: "+05:30"))
        #expect(parsed.date == utc("2019-07-04T12:52:01Z"))
        #expect(parsed.tzMinutes == 330)
    }

    @Test func missingOffsetIsUTCWithNoZone() throws {
        let parsed = try #require(ExifDate.parse("2019:07:04 18:22:01", offset: nil))
        #expect(parsed.date == utc("2019-07-04T18:22:01Z"))
        #expect(parsed.tzMinutes == nil)
    }

    @Test func negativeOffsetShiftsTheOtherWay() throws {
        let parsed = try #require(ExifDate.parse("2019:07:04 18:22:01", offset: "-05:30"))
        #expect(parsed.date == utc("2019-07-04T23:52:01Z"))
        #expect(parsed.tzMinutes == -330)
    }

    @Test func allZeroDateIsNil() {
        #expect(ExifDate.parse("0000:00:00 00:00:00", offset: nil) == nil)
        #expect(ExifDate.parse("0000:00:00 00:00:00", offset: "+05:30") == nil)
    }

    private func utc(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: text)!
    }
}
