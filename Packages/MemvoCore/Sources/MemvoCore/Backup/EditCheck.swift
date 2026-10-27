import Foundation

/// Whether a backed-up photo's edit on the phone may not be in the cloud yet. Only the phone knows when it last changed
/// a photo, so without that date (lost in index rebuilds before it was kept, or never known) the answer is "check":
/// an edited photo is uploaded at most once too often, never missed.
public enum EditCheck {
    /// The backup should compare the phone's edit with the cloud's.
    public static func needsUpload(phoneHasEdit: Bool, modified: Date?, backedUpAt since: Date?) -> Bool {
        guard phoneHasEdit else { return false }
        guard let since else { return true }
        guard let modified else { return false }
        return modified > since.addingTimeInterval(1)
    }

    /// Free Up Space must keep the phone copy: deleting it could lose an edit the cloud doesn't have. Favouriting also
    /// moves the date, so only an edited photo with a newer date (or no date to compare) counts.
    public static func mayLoseEdit(cloudHasEdit: Bool, phoneHasEdit: Bool, modified: Date?, backedUpAt since: Date?) -> Bool {
        guard phoneHasEdit else { return false }
        if !cloudHasEdit { return true }
        guard let since else { return true }
        guard let modified else { return false }
        return modified > since.addingTimeInterval(60)
    }
}

extension MediaItem {
    /// `self` rebuilt from the channel, with what only this device knows taken from `local`: which photo it is, when it
    /// was backed up and last changed, queue and check state. A full scan rebuilt items without the dates, and edits
    /// made after the backup were then never detected.
    public func keepingLocalState(from local: MediaItem) -> MediaItem {
        var item = self
        item.localIdentifier = local.localIdentifier
        item.verifiedAt = local.verifiedAt
        item.uploadedAt = local.uploadedAt ?? item.uploadedAt
        item.assetModifiedAt = local.assetModifiedAt ?? item.assetModifiedAt
        item.chosen = local.chosen
        item.editCheck = local.editCheck
        item.streamingCopySkipped = local.streamingCopySkipped
        item.screenCopySkipped = local.screenCopySkipped
        item.extrasChecked = local.extrasChecked
        item.uti = local.uti ?? item.uti
        return item
    }
}
