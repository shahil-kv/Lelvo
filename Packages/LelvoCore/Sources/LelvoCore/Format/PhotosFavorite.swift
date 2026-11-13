import Foundation

/// Keeps the favorite in Apple Photos and in the Telegram library the same for items on this device (#99). Photos has
/// no history Lelvo can trust for "who changed it last", so each item remembers the favorite Photos had last time it was
/// checked. When Photos still has that value, the user didn't touch it there: the Telegram library's value (from the
/// backup and the newest note) goes into Photos. When Photos changed since, that is the user's newer choice: it's sent
/// as a note, so every other device follows.
public enum PhotosFavorite {
    public enum Decision: Equatable, Sendable {
        /// They agree, or there's nothing to go by: only remember what Photos has.
        case remember
        /// Set the favorite in Photos to this value.
        case setInPhotos(Bool)
        /// Send Photos' value to the other devices as a note.
        case sendNote(Bool)
    }

    /// - Parameters:
    ///   - photos: the favorite in Photos now.
    ///   - lastSeen: the favorite Photos had last time, nil before the first check.
    ///   - library: the item's favorite in the Telegram library, nil when its backup didn't record one.
    ///   - noteDecides: a note (sent or waiting) sets this item's favorite, so `library` isn't just the backup's value.
    public static func decide(photos: Bool, lastSeen: Bool?, library: Bool?, noteDecides: Bool) -> Decision {
        guard let library else {
            // The backup didn't record a favorite (captions only carry it when set), so Photos is never changed from
            // it. But a heart added or removed in Photos since the last check is the user's choice: it goes to the
            // other devices like any other change.
            if let lastSeen, photos != lastSeen { return .sendNote(photos) }
            return .remember
        }
        guard library != photos else { return .remember }
        guard let lastSeen else {
            // First check: nothing says which side changed last. A note is a change made in Lelvo after the backup, so
            // it wins; without one, Photos differs from what was backed up, so the user changed it in Photos.
            return noteDecides ? .setInPhotos(library) : .sendNote(photos)
        }
        return photos == lastSeen ? .setInPhotos(library) : .sendNote(photos)
    }
}
