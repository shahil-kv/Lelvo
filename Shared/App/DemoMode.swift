import Foundation
import MemvoCore

/// App Review demo. A reserved phone number and code open a sample library bundled with the app (iOS/DemoLibrary),
/// so a reviewer can try every feature without a Telegram account. In demo mode nothing talks to Telegram and the
/// Photos library is only read, never changed: "Back up now" simulates uploading the demo's newest items.
/// The details reviewers get are in docs/APP_STORE_RELEASE.md (Phase 2.3).
enum DemoMode {
    /// 555-01xx numbers are reserved for fiction in the North American plan, so this can never be a real account.
    static let phone = "+15550100199"
    static let code = "24680"

    private static let activeKey = "demoMode"
    private static let pendingKey = "demoModePending"
    private static let idPrefix = "demo-"

    static var isActive: Bool { UserDefaults.standard.bool(forKey: activeKey) }

    /// The bundled sample files (iPhone app only).
    static var folder: URL? { Bundle.main.url(forResource: "DemoLibrary", withExtension: nil) }

    static func matches(phone: String) -> Bool {
        folder != nil && phone.filter(\.isNumber) == Self.phone.filter(\.isNumber)
    }

    /// The bundled file for a demo item; nil for every real item.
    static func fileURL(for item: MediaItem) -> URL? {
        guard item.id.hasPrefix(idPrefix), let folder else { return nil }
        return folder.appendingPathComponent(String(item.id.dropFirst(idPrefix.count)))
    }

    /// Replaces the local index with the demo library. The newest items wait for "Back up now".
    static func enter(store: LibraryStore) {
        UserDefaults.standard.set(true, forKey: activeKey)
        UserDefaults.standard.set(true, forKey: pendingKey)
        try? store.deleteAll()
        try? store.upsert(entries().filter { $0.pending != true }.map(item))
        appLog("Demo mode: sample library loaded")
    }

    /// Items "on the phone" that the simulated backup uploads; empty once it has run.
    static func pendingItems() -> [MediaItem] {
        guard UserDefaults.standard.bool(forKey: pendingKey) else { return [] }
        return entries().filter { $0.pending == true }.map(item)
    }

    static func pendingUploaded() { UserDefaults.standard.set(false, forKey: pendingKey) }

    /// Sign out: back to a normal, empty app.
    static func exit() {
        UserDefaults.standard.removeObject(forKey: activeKey)
        UserDefaults.standard.removeObject(forKey: pendingKey)
    }

    // MARK: - Manifest

    private struct Manifest: Decodable { let items: [Entry] }

    private struct Entry: Decodable {
        let file: String
        let name: String
        let kind: String
        let daysAgo: Int
        let minutes: Int
        let w: Int
        let h: Int
        let size: Int64
        var duration: Double?
        var pending: Bool?
        var lat: Double?
        var lon: Double?
        var albums: [String]?
        var favorite: Bool?
    }

    private static func entries() -> [Entry] {
        guard let url = folder?.appendingPathComponent("manifest.json"), let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return [] }
        return manifest.items
    }

    /// Dates count back from today, so the demo always looks like a recent library.
    private static func item(_ e: Entry) -> MediaItem {
        let today = Calendar.current.startOfDay(for: Date())
        let date = today.addingTimeInterval(Double(-e.daysAgo) * 86_400 + Double(9 * 60 + e.minutes) * 60)
        var item = MediaItem(id: idPrefix + e.file, localIdentifier: nil,
                             sha256: String(repeating: "0", count: 48) + String(format: "%016llx", stableHash(e.file)),
                             filename: e.name, kind: e.kind == "video" ? .video : .photo, creationDate: min(date, Date()),
                             latitude: e.lat, longitude: e.lon, pixelWidth: e.w, pixelHeight: e.h, duration: e.duration,
                             fileSize: e.size, status: .backedUp)
        item.uploadedAt = item.creationDate
        item.verifiedAt = item.creationDate
        item.albums = e.albums
        item.favorite = e.favorite
        item.setParts([RemoteFile(messageId: Int64(stableHash(e.file) % 1_000_000), fileId: "demo", fileUniqueId: idPrefix + e.file, size: e.size)],
                      role: "o", expected: 1)
        return item
    }

    /// FNV-1a: the same number on every launch (Swift's `hashValue` is not).
    private static func stableHash(_ s: String) -> UInt64 {
        s.utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }
}
