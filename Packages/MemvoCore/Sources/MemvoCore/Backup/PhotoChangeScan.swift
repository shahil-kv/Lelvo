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

    /// Queued items whose photo was deleted from the phone before it was uploaded. Photos' change history only lists
    /// new and edited photos, so without this they'd count as waiting until an upload lane reached them.
    /// `present`: the queued photos Photos still has. Items being uploaded are left to the lane that has them, and
    /// when Photos finds none of them while the library isn't empty, nothing is dropped (a Photos hiccup, not 50 deletions).
    public static func queuedButDeleted(_ items: [MediaItem], present: Set<String>, libraryIsEmpty: Bool) -> [MediaItem] {
        if present.isEmpty && !libraryIsEmpty { return [] }
        return items.filter { $0.status == .queued && $0.localIdentifier.map { !present.contains($0) } == true }
    }
}
