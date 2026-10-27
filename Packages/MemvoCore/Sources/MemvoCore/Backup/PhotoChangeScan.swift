import Foundation

/// Finding new photos: from Photos' change history since the last search (iOS 16, macOS 13), or by reading the whole
/// library. Background runs have little time, and walking 50k photos took a good part of it before anything uploaded.
public enum PhotoChangeScan {
    /// The whole library is still read at least this often, in case a change was ever missed.
    public static let fullScanEvery: TimeInterval = 7 * 24 * 3600

    /// Whether the change history may be used instead of reading the whole library. Never without a token from an
    /// earlier search, after the backup selection (albums, media, dates, screenshots, hidden) changed, or when the last
    /// full read is too old; Photos losing its history back to the token is handled by the caller (it then reads all).
    public static func canUseChanges(hasToken: Bool, savedSelection: String?, selection: String, lastFullScan: Date?, now: Date) -> Bool {
        guard hasToken, savedSelection == selection, let lastFullScan else { return false }
        return now.timeIntervalSince(lastFullScan) < fullScanEvery && now >= lastFullScan
    }
}
