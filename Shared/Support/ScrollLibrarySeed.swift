#if DEBUG
import Foundation
import LelvoCore

/// Debug only: replaces the local index with synthetic items so grid scroll and prefetch can be measured
/// without a real 40k Photos library. Demo mode and UI tests only: `deleteAll` also drops changes waiting to be sent and the backed-up links.
enum ScrollLibrarySeed {
    /// Builds `count` backed-up cloud-only items spanning many years, upserts them, and seeds thumbnail colours.
    @discardableResult
    static func load(count: Int, albums: Bool = true) -> Int {
        // The lab screen is gated on demo mode; UI tests run on their own throwaway data.
        let store = AppEnvironment.shared.store
        let now = Date()
        let items = (0..<count).map { i -> MediaItem in
            var item = MediaItem(localIdentifier: nil, sha256: String(format: "%064d", i), filename: "IMG_\(1000 + i).HEIC",
                                 kind: i % 7 == 0 ? .video : .photo, creationDate: now.addingTimeInterval(Double(-i) * 9_000),
                                 fileSize: 2_000_000, status: .backedUp)
            if i % 7 == 0 { item.duration = Double(5 + i % 90) }
            let trip = (200..<240).contains(i % 1000)
            let jitter = Double(i % 13) * 0.002
            item.latitude = (trip ? 15.49 : 9.93) + jitter
            item.longitude = (trip ? 73.82 : 76.26) + jitter
            item.setParts([RemoteFile(messageId: Int64(i + 1), fileId: "demo", fileUniqueId: "demo\(i)", size: 2_000_000)],
                          role: "o", expected: 1)
            if albums {
                item.favorite = i % 11 == 0
                item.albums = ["Family \(i % 5 + 1)"]
            }
            return item
        }
        try? store.deleteAll()
        try? store.upsert(items)
        ThumbnailPipeline.shared.seedDemoThumbnails(ids: items.map { "cloud-\($0.id)" })
        appLog("Scroll library: loaded \(count) synthetic items")
        return count
    }
}
#endif
