import Foundation
import ImageIO
import AVFoundation
import LelvoCore

/// Thumbnails and full-size originals for cloud items, with an in-memory cache, a 300 MB thumbnail
/// disk cache and a size-capped LRU cache for viewed originals. Videos stream instead (`StreamingAsset`).
final class CloudMediaService: @unchecked Sendable {
    private unowned let env: AppEnvironment
    private let memory = NSCache<NSString, PlatformImage>()
    /// Thumbnails are small; more in parallel fills the grid faster without starving full-size downloads.
    /// Thumbnails being downloaded: 8 at a time, tiles on screen first (`PriorityGate`).
    private let gate = PriorityGate(limit: 8)
    private let inflight = InflightRegistry()

    init(environment: AppEnvironment) {
        self.env = environment
        memory.countLimit = 800
        memory.totalCostLimit = 120 * 1024 * 1024
    }

    static func thumbnailKey(_ item: MediaItem) -> String { "t_\(item.id)" }
    static func originalKey(_ item: MediaItem, role: String) -> String { "o_\(item.id)_\(role)" }

    func cachedThumbnail(for item: MediaItem) -> PlatformImage? {
        memory.object(forKey: item.id as NSString)
    }

    /// `urgent`: a tile or screen is waiting for it; false for loading ahead of the scroll.
    func thumbnail(for item: MediaItem, urgent: Bool = true) async throws -> PlatformImage {
        if let img = memory.object(forKey: item.id as NSString) { return img }
        if let demo = DemoMode.fileURL(for: item) {
            guard let image = await Self.demoImage(demo) else { throw MediaReader.ReadError.missing }
            memory.setObject(image, forKey: item.id as NSString)
            return image
        }
        let key = Self.thumbnailKey(item)
        // Already waiting as a prefetch: this request joins it below, so move it to the front.
        if urgent { await gate.promote(key) }
        let url = try await inflight.run(key) { [self] in
            if let cached = env.thumbnailCache.url(for: key) { return cached }
            // Cold start: wait for the Telegram session instead of failing the tile.
            try await env.td.waitUntilReady(timeout: 30)
            let data = try await gate.run(key: key, urgent: urgent) { try await self.env.reader.thumbnailData(item) }
            return try env.thumbnailCache.store(data: data, for: key, ext: "jpg")
        }
        guard let image = Self.downsampled(url, maxPixel: 400) else { throw MediaReader.ReadError.missing }
        memory.setObject(image, forKey: item.id as NSString, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
        return image
    }

    /// What the user sees: the edited version when the item was edited in Photos, else the original.
    func displayed(for item: MediaItem, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        try await original(for: item, role: item.hasEdit == true && !item.parts("e").isEmpty ? .edited : .original, progress: progress)
    }

    static func displayedFilename(_ item: MediaItem) -> String {
        item.hasEdit == true && !item.parts("e").isEmpty ? (item.editedFilename ?? item.filename) : item.filename
    }

    /// Downloads (or returns the cached) full original for photos, sharing and saving.
    func original(for item: MediaItem, role: UploadRole = .original, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        if let demo = DemoMode.fileURL(for: item) { return demo }
        let r = MediaItem.captionRole(role)
        let name = role == .pairedVideo ? (item.pairedVideoFilename ?? "video.mov")
            : role == .edited ? (item.editedFilename ?? item.filename) : item.filename
        let ext = (name as NSString).pathExtension.lowercased()
        let key = Self.originalKey(item, role: r)
        env.originalsCache.setCapacity(Prefs.mediaCacheBytes)
        return try await inflight.run(key) { [self] in
            if let cached = env.originalsCache.url(for: key) { return cached }
            try await env.td.waitUntilReady(timeout: 30)
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try await env.reader.download(item, role: r, to: tmp, progress: progress)
            return try env.originalsCache.store(file: tmp, for: key, ext: ext.isEmpty ? "bin" : ext)
        }
    }

    /// One stored file of an item, by caption role, as a temporary file named like the original file (Photos reads the
    /// type from the extension). The caller deletes its folder. Originals and edits come from the viewing cache.
    func restoreFile(for item: MediaItem, role: String, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let name: String
        let cached: URL
        switch role {
        case "o": cached = try await original(for: item, role: .original, progress: progress); name = item.filename
        case "pv": cached = try await original(for: item, role: .pairedVideo); name = item.pairedVideoFilename ?? "video.mov"
        case "e": cached = try await original(for: item, role: .edited); name = item.editedFilename ?? item.filename
        default:
            try await env.td.waitUntilReady(timeout: 30)
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try await env.reader.download(item, role: role, to: tmp, evict: true)
            name = item.roleNames?[role] ?? "\(role).bin"
            defer { try? FileManager.default.removeItem(at: tmp) }
            return try shareableCopy(of: tmp, filename: name)
        }
        return try shareableCopy(of: cached, filename: name)
    }

    /// The screen copy of a big photo (role `d`), downloaded once and cached like originals.
    func screenCopy(for item: MediaItem) async throws -> URL {
        let key = Self.originalKey(item, role: "d")
        return try await inflight.run(key) { [self] in
            if let cached = env.originalsCache.url(for: key) { return cached }
            try await env.td.waitUntilReady(timeout: 30)
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try await env.reader.download(item, role: "d", to: tmp)
            return try env.originalsCache.store(file: tmp, for: key, ext: "jpg")
        }
    }

    /// What a viewer shows first: the original when it's already here, else the screen copy when there is one (a
    /// few hundred KB instead of up to 40 MB), else the original. Zooming in, sharing and saving use the original.
    func shownFirst(for item: MediaItem) async throws -> (url: URL, isScreenCopy: Bool) {
        if item.hasScreenCopy, !hasDisplayed(item), let copy = try? await screenCopy(for: item) { return (copy, true) }
        return (try await displayed(for: item), false)
    }

    func hasCachedScreenCopy(_ item: MediaItem) -> Bool {
        env.originalsCache.url(for: Self.originalKey(item, role: "d")) != nil
    }

    /// The original (or edit) of a cloud photo if it's already in the viewing cache, for making a screen copy without
    /// downloading anything.
    func cachedDisplayed(_ item: MediaItem) -> URL? {
        let role = item.hasEdit == true && !item.parts("e").isEmpty ? "e" : "o"
        return env.originalsCache.url(for: Self.originalKey(item, role: role))
    }

    /// Neighbouring cloud photos are fetched ahead only up to this size (ProRAW and the like would cost too much data).
    static let photoPrefetchLimit: Int64 = 15 << 20

    /// The full original of a cloud photo is already on this device (opening it needs no download).
    func hasDisplayed(_ item: MediaItem) -> Bool {
        let role = item.hasEdit == true && !item.parts("e").isEmpty ? "e" : "o"
        return env.originalsCache.url(for: Self.originalKey(item, role: role)) != nil
    }

    /// Fetches a neighbouring cloud photo's original ahead of the swipe: Wi-Fi only, not huge files.
    func prefetchPhoto(_ item: MediaItem) async {
        guard item.kind != .video, item.isViewableFromCloud, !NetworkStatus.shared.isExpensive, !DemoMode.isActive,
              !hasDisplayed(item) else { return }
        // The screen copy is what the swipe shows first, and small whatever the original's size.
        if item.hasScreenCopy { _ = try? await screenCopy(for: item); return }
        guard item.fileSize <= Self.photoPrefetchLimit else { return }
        _ = try? await displayed(for: item)
    }

    /// Log line for each cloud photo opened, so slow ones can be told apart: Telegram's speed (size ÷ time ≈ the
    /// usual ~1 MB/s), or the app (much longer than the size explains).
    static func logPhotoTiming(_ item: MediaItem, opened: Date, wasCached: Bool, screenCopy: Bool = false) {
        let took = Date().timeIntervalSince(opened)
        let bytes = screenCopy ? item.parts("d").reduce(0) { $0 + $1.size } : item.fileSize
        appLog(String(format: "Photo timing: %@: %@ after %.2f s (%@, %@)", item.filename, screenCopy ? "screen copy" : "sharp", took,
                      Format.bytes(bytes),
                      wasCached ? "already on this device" : String(format: "downloaded at %@/s", Format.bytes(Int64(Double(bytes) / max(took, 0.05))))))
    }

    /// Medium-size decode used while the full image loads (progressive: thumbnail → screen-size → full).
    static func downsampled(_ url: URL, maxPixel: CGFloat) -> PlatformImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else { return nil }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOptions as CFDictionary) else { return nil }
        return PlatformImage(cgImage: cg)
    }

    /// First frame of a bundled demo clip (cloud videos get their thumbnail from Telegram).
    private static func demoImage(_ url: URL) async -> PlatformImage? {
        if let photo = downsampled(url, maxPixel: 400) { return photo }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 400, height: 400)
        guard let cg = try? await generator.image(at: .zero).image else { return nil }
        return PlatformImage(cgImage: cg)
    }

    /// Copies a cached original to a temp file with its real name (for sharing / saving).
    func shareableCopy(of url: URL, filename: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(filename.sanitizedFilename)
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }

    struct CacheUsage {
        let thumbnails: Int64
        let originals: Int64
        let telegram: Int64
        var total: Int64 { thumbnails + originals + telegram }
    }

    var cacheUsage: CacheUsage {
        CacheUsage(thumbnails: env.thumbnailCache.totalSize, originals: env.originalsCache.totalSize, telegram: env.td.storageUsage())
    }

    func clearCaches() async {
        memory.removeAllObjects()
        env.thumbnailCache.clear()
        env.originalsCache.clear()
        await env.td.clearAllFiles()
        env.reader.forgetCaches()
        let left = cacheUsage
        appLog("Cleared caches: \(Format.bytes(left.total)) left (thumbnails \(Format.bytes(left.thumbnails)), viewed \(Format.bytes(left.originals)), Telegram \(Format.bytes(left.telegram)))")
    }

    func trimMemory() { memory.removeAllObjects() }
}

/// Coalesces concurrent requests for the same key into one download.
actor InflightRegistry {
    private var tasks: [String: Task<URL, Swift.Error>] = [:]

    func run(_ key: String, _ body: @escaping @Sendable () async throws -> URL) async throws -> URL {
        if let existing = tasks[key] { return try await existing.value }
        let task = Task { try await body() }
        tasks[key] = task
        defer { tasks[key] = nil }
        return try await task.value
    }
}
