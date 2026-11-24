import Foundation

/// Where a year starts along the date scrubber, as the platform measured it (a fraction from the top, 0 to 1).
public struct ScrubberMark: Equatable, Sendable {
    public let year: Int
    public let fraction: Double
    public init(year: Int, fraction: Double) {
        self.year = year
        self.fraction = fraction
    }
}

/// Picks the year labels drawn along the scrubber track. The positions come from the real library, so a library that
/// starts in 2015 ends its track at 2015 and one with a gap years wide keeps the gap: nothing is spread evenly over time.
public enum ScrubberTicks {
    /// Short libraries need no marks: the scrubber's bubble is enough.
    public static let minimumViewports = 8.0

    /// `marks` in track order (top first), one per section. Consecutive marks of the same year become one label at the
    /// first of them; labels closer than one slot (`1 / maxLabels` of the track) to the last kept one are dropped.
    public static func make(marks: [ScrubberMark], maxLabels: Int) -> [ScrubberMark] {
        guard maxLabels > 0 else { return [] }
        var yearStarts: [ScrubberMark] = []
        for mark in marks where mark.fraction.isFinite {
            if yearStarts.last?.year == mark.year { continue }
            yearStarts.append(ScrubberMark(year: mark.year, fraction: min(1, max(0, mark.fraction))))
        }
        let slot = 1.0 / Double(maxLabels)
        var kept: [ScrubberMark] = []
        for mark in yearStarts {
            if let last = kept.last, mark.fraction - last.fraction < slot { continue }
            kept.append(mark)
        }
        return kept
    }

    /// Whether the library is long enough to draw marks at all.
    public static func isLongEnough(contentHeight: Double, viewportHeight: Double) -> Bool {
        viewportHeight > 0 && contentHeight / viewportHeight > minimumViewports
    }
}
