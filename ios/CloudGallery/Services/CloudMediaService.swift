import Foundation
import ImageIO
import CloudGalleryCore

/// Thumbnails and full-size originals for cloud items, with an in-memory cache, a 300 MB thumbnail
/// disk cache and a size-capped LRU cache for viewed originals. Videos stream instead (`StreamingAsset`).
final class CloudMediaService: @unchecked Sendable {
    private unowned let env: AppEnvironment
    private let memory = NSCache<NSString, PlatformImage>()
    /// Thumbnails are small; more in parallel fills the grid faster without starving full-size downloads.
    private let gate = DownloadGate(limit: 8)
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

    func thumbnail(for item: MediaItem) async throws -> PlatformImage {
        if let img = memory.object(forKey: item.id as NSString) { return img }
        let key = Self.thumbnailKey(item)
        let url = try await inflight.run(key) { [self] in
            if let cached = env.thumbnailCache.url(for: key) { return cached }
            // Cold start: wait for the Telegram session instead of failing the tile.
            try await env.td.waitUntilReady(timeout: 30)
            let data = try await gate.run { try await self.env.reader.thumbnailData(item) }
            return try env.thumbnailCache.store(data: data, for: key, ext: "jpg")
        }
        guard let image = Self.downsampled(url, maxPixel: 400) else { throw MediaReader.ReadError.missing }
        memory.setObject(image, forKey: item.id as NSString, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
        return image
    }

    /// What the user sees: the edited version when the item was edited in Photos, else the original.
    func displayed(for item: MediaItem, progress: ((Double) -> Void)? = nil) async throws -> URL {
        try await original(for: item, role: item.hasEdit == true && !item.parts("e").isEmpty ? .edited : .original, progress: progress)
    }

    static func displayedFilename(_ item: MediaItem) -> String {
        item.hasEdit == true && !item.parts("e").isEmpty ? (item.editedFilename ?? item.filename) : item.filename
    }

    /// Downloads (or returns the cached) full original for photos, sharing and saving.
    func original(for item: MediaItem, role: UploadRole = .original, progress: ((Double) -> Void)? = nil) async throws -> URL {
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

/// Limits concurrent downloads.
actor DownloadGate {
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func run<T>(_ body: @Sendable () async throws -> T) async throws -> T {
        if active >= limit { await withCheckedContinuation { waiters.append($0) } } else { active += 1 }
        defer { release() }
        return try await body()
    }

    private func release() {
        if waiters.isEmpty { active -= 1 } else { waiters.removeFirst().resume() }
    }
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
