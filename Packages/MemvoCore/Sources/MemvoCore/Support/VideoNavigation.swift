import Foundation

/// Rules for moving around a video in the viewer: skipping, the frame strip under the scrubber, and where a long video
/// starts when it's opened again.
public enum VideoNavigation {
    /// Seconds a double-tap on either side of the video skips.
    public static let skip: Double = 10
    /// Only videos at least this long remember where they were left, like Photos.
    public static let resumeMinimumDuration: Double = 120

    /// Where a skip of `delta` seconds lands, kept inside the video.
    public static func skipTarget(current: Double, duration: Double, by delta: Double) -> Double {
        let now = current.isFinite ? current : 0
        guard duration.isFinite, duration > 0 else { return max(0, now + delta) }
        return min(max(0, now + delta), duration)
    }

    /// Evenly spaced frame times for the strip: the middle of each of `count` equal slices.
    public static func stripTimes(duration: Double, count: Int) -> [Double] {
        guard duration.isFinite, duration > 0, count > 0 else { return [] }
        let slice = duration / Double(count)
        return (0..<count).map { (Double($0) + 0.5) * slice }
    }

    /// Whether `position` is worth remembering: a long video, past its first seconds and not at its end.
    public static func shouldRemember(position: Double, duration: Double) -> Bool {
        guard duration.isFinite, position.isFinite, duration >= resumeMinimumDuration else { return false }
        return position >= 10 && position < duration - max(10, duration * 0.05)
    }

    /// Where to start a video last left at `saved`; nil starts from the beginning.
    public static func resumePosition(saved: Double?, duration: Double) -> Double? {
        guard let saved, shouldRemember(position: saved, duration: duration) else { return nil }
        return saved
    }
}
