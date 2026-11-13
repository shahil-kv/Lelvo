import Foundation

/// EXIF `DateTimeOriginal` (`yyyy:MM:dd HH:mm:ss`) and optional `OffsetTimeOriginal` (`±HH:MM`).
/// A missing offset is the clock read as UTC, and `tzMinutes` stays nil: the file never named a zone,
/// and guessing this phone's zone would stamp someone else's photos with the wrong one.
/// Cameras write `0000:00:00 00:00:00` when they don't know the time; that is not a date.
public enum ExifDate {
    public static func parse(_ value: String, offset: String?) -> (date: Date, tzMinutes: Int?)? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = text.split(separator: " ")
        guard pieces.count == 2 else { return nil }
        let dateParts = pieces[0].split(separator: ":")
        let timeParts = pieces[1].split(separator: ":")
        guard dateParts.count == 3, timeParts.count == 3,
              let year = Int(dateParts[0]), let month = Int(dateParts[1]), let day = Int(dateParts[2]),
              let hour = Int(timeParts[0]), let minute = Int(timeParts[1]), let second = Int(timeParts[2]),
              (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let parts = DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: year, month: month,
                                   day: day, hour: hour, minute: minute, second: second)
        guard let utc = calendar.date(from: parts) else { return nil }
        // A lenient calendar turns 31 Feb into March. An impossible clock is unknown, not a nearby day.
        let back = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: utc)
        guard back.year == year, back.month == month, back.day == day,
              back.hour == hour, back.minute == minute, back.second == second else { return nil }

        guard let zone = offset.flatMap(zoneSeconds) else { return (utc, nil) }
        return (utc.addingTimeInterval(TimeInterval(-zone.seconds)), zone.minutes)
    }

    /// `±HH:MM`, `±HH:MM:SS` or `±HHMM`. Seconds are applied to the instant; `tz` is whole minutes, as captions store it.
    private static func zoneSeconds(_ offset: String) -> (minutes: Int, seconds: Int)? {
        let text = offset.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sign = text.first, sign == "+" || sign == "-" else { return nil }
        let body = text.dropFirst()
        let fields: [Substring]
        if body.contains(":") {
            fields = body.split(separator: ":").filter { !$0.isEmpty }
        } else if body.count == 4 || body.count == 6 {
            fields = stride(from: 0, to: body.count, by: 2).map { index in
                let start = body.index(body.startIndex, offsetBy: index)
                return body[start..<body.index(start, offsetBy: 2)]
            }
        } else {
            return nil
        }
        guard fields.count == 2 || fields.count == 3,
              let hours = Int(fields[0]), let mins = Int(fields[1]),
              (0...23).contains(hours), (0...59).contains(mins) else { return nil }
        var seconds = 0
        if fields.count == 3 {
            guard let secs = Int(fields[2]), (0...59).contains(secs) else { return nil }
            seconds = secs
        }
        let minutes = hours * 60 + mins
        let signedMinutes = sign == "-" ? -minutes : minutes
        let signedSeconds = sign == "-" ? -(minutes * 60 + seconds) : minutes * 60 + seconds
        return (signedMinutes, signedSeconds)
    }
}
