import Foundation

/// Maps a calendar date to the scrubber's 0…1 fraction. The gallery is newest-first: fraction 0 is the top
/// (newest), 1 is the bottom (oldest). Used by Jump to date on every platform.
public enum JumpToDate {
    /// Where to scroll for `target` in a newest-first date list. Empty → 0; one item → 0.
    public static func fraction(target: Date, datesNewestFirst: [Date]) -> Double {
        guard datesNewestFirst.count > 1 else { return 0 }
        // First item at or older than the target (same ordering as Android's scrubber index).
        if let i = datesNewestFirst.firstIndex(where: { $0 <= target }) {
            return Double(i) / Double(datesNewestFirst.count - 1)
        }
        // Target is older than every photo: go to the bottom.
        return 1
    }

    /// The month/year wheels' range from the library (inclusive). Empty → current year only.
    public static func yearRange(in dates: [Date], calendar: Calendar = .current, now: Date = Date()) -> ClosedRange<Int> {
        let years = dates.compactMap { calendar.component(.year, from: $0) }
        let thisYear = calendar.component(.year, from: now)
        guard let lo = years.min(), let hi = years.max() else { return thisYear...thisYear }
        return min(lo, thisYear)...max(hi, thisYear)
    }
}
