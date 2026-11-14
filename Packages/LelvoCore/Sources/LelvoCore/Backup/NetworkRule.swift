import Foundation

/// What may upload on the current connection.
public enum NetworkRule {
    public enum Allowance: Equatable, Sendable { case everything, photosOnly, nothing }

    /// Wi-Fi only off: everything, on any connection. On: everything on Wi-Fi; on mobile data or a hotspot, photos
    /// only when "Photos on mobile data" is on (a photo is a few MB, a video can be hundreds). Low Data Mode is the
    /// person asking iPhone to save data, so nothing goes up then.
    public static func allowance(wifiOnly: Bool, photosOnMobile: Bool, expensive: Bool, lowDataMode: Bool) -> Allowance {
        guard wifiOnly else { return .everything }
        if lowDataMode { return .nothing }
        if !expensive { return .everything }
        return photosOnMobile ? .photosOnly : .nothing
    }
}
