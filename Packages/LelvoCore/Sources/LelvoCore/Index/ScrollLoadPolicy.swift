import Foundation

/// Decides when the grid is flinging so fast that starting thumbnail loads is wasted work (the tiles are gone
/// before they finish). Hysteresis stops it flapping around the threshold. The Android app uses the same numbers.
public struct ScrollLoadPolicy: Sendable, Equatable {
    public static let deferAbove: Double = 3000   // points per second
    public static let resumeBelow: Double = 1800

    public private(set) var isDeferring = false

    public init() {}

    /// Feeds the latest scroll speed and returns whether loads should be held back. NaN and negatives count as 0.
    @discardableResult
    public mutating func update(speedPointsPerSecond: Double) -> Bool {
        let speed = speedPointsPerSecond.isFinite && speedPointsPerSecond > 0 ? speedPointsPerSecond : 0
        if isDeferring {
            if speed < Self.resumeBelow { isDeferring = false }
        } else if speed >= Self.deferAbove {
            isDeferring = true
        }
        return isDeferring
    }

    /// How many rows' worth of tiles to load ahead: none while flinging, fewer while fast, the usual amount otherwise.
    public static func prefetchCount(speed: Double) -> Int {
        let s = speed.isFinite && speed > 0 ? speed : 0
        if s >= deferAbove { return 0 }
        if s >= resumeBelow { return 12 }
        return 30
    }
}
