import Foundation

/// The order a backup run uploads in. One large video can take many minutes on an account Telegram slows down, so
/// photos go first and most of the library is safe sooner. A half-done upload (some parts already in the channel)
/// is finished before anything new starts. Newest first within each group.
public enum UploadOrder {
    public static func sorted(_ items: [MediaItem]) -> [MediaItem] {
        items.sorted { a, b in
            let ga = group(a), gb = group(b)
            if ga != gb { return ga < gb }
            return (a.creationDate ?? .distantPast) > (b.creationDate ?? .distantPast)
        }
    }

    /// A background run has about 25 seconds. Photos and small videos only: a big video can't finish, and a half-sent
    /// one only wastes the time. A video of unknown size (0) counts as big. Ente does the same (photos only).
    public static func forShortRun(_ items: [MediaItem], maxBytes: Int64 = 50 * 1_048_576) -> [MediaItem] {
        sorted(items).filter { $0.kind != .video || ($0.fileSize > 0 && $0.fileSize <= maxBytes) }
    }

    private static func group(_ item: MediaItem) -> Int {
        // An edit check also has parts in the channel, from its finished backup: it isn't half done.
        if item.editCheck != true, item.cloudParts?.isEmpty == false || item.uploadResume?.isEmpty == false { return 0 }
        return item.kind == .video ? 2 : 1
    }
}
