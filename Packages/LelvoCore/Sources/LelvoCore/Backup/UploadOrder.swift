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

    /// A background run has about 25 seconds. Photos only, like Ente: on the iPhone a 12 MB video took 26 s on an
    /// account Telegram slows down (no Premium), so even small videos ran past the time iOS gives. They go up when
    /// Lelvo is open or overnight.
    public static func forShortRun(_ items: [MediaItem]) -> [MediaItem] {
        sorted(items).filter { $0.kind != .video }
    }

    private static func group(_ item: MediaItem) -> Int {
        // An edit check also has parts in the channel, from its finished backup: it isn't half done.
        if item.editCheck != true, item.cloudParts?.isEmpty == false || item.uploadResume?.isEmpty == false { return 0 }
        return item.kind == .video ? 2 : 1
    }
}
