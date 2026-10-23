import Foundation
import UIKit
import CloudGalleryCore

/// Downloads thumbnails and originals from Telegram on demand, decrypts E2E files, and caches them
/// in Caches/ (thumbnails in their own cache, originals in a size-capped LRU cache).
final class CloudMediaService: @unchecked Sendable {
    private unowned let env: AppEnvironment
    private let memory = NSCache<NSString, UIImage>()
    private let gate = DownloadGate(limit: 4)
    private let inflight = InflightRegistry()

    init(environment: AppEnvironment) {
        self.env = environment
        memory.countLimit = 600
    }

    func cachedThumbnail(for item: LibraryItem) -> UIImage? {
        memory.object(forKey: item.id as NSString)
    }

    func thumbnail(for item: LibraryItem) async throws -> UIImage {
        if let img = memory.object(forKey: item.id as NSString) { return img }
        guard let remote = item.thumbnail else { throw TelegramError.missingResult }
        let key = "t_\(remote.fileUniqueId)"
        let url = try await inflight.run(key) { [self] in
            if let cached = env.thumbnailCache.url(for: key) { return cached }
            return try await gate.run { try await self.download(remote, encrypted: item.encrypted, key: key, ext: "jpg", into: self.env.thumbnailCache) }
        }
        guard let image = UIImage(contentsOfFile: url.path) else { throw TelegramError.decoding("Thumbnail is not an image") }
        memory.setObject(image, forKey: item.id as NSString)
        return image
    }

    /// Downloads (or returns the cached) original/paired video. Throws for files over 20 MB.
    func original(for item: LibraryItem, role: UploadRole = .original) async throws -> URL {
        guard let remote = item.remote(for: role) else { throw TelegramError.missingResult }
        guard remote.size <= TelegramClient.maxDownloadBytes else { throw TelegramError.fileTooLargeToDownload }
        let name = role == .pairedVideo ? (item.pairedVideoFilename ?? "video.mov") : item.filename
        let ext = (name as NSString).pathExtension.lowercased()
        let key = "o_\(remote.fileUniqueId)"
        env.originalsCache.setCapacity(Prefs.cacheCapBytes)
        return try await inflight.run(key) { [self] in
            if let cached = env.originalsCache.url(for: key) { return cached }
            return try await download(remote, encrypted: item.encrypted, key: key, ext: ext.isEmpty ? "bin" : ext, into: env.originalsCache)
        }
    }

    private func download(_ remote: RemoteFile, encrypted: Bool, key: String, ext: String, into cache: LRUDiskCache) async throws -> URL {
        guard let client = env.client() else { throw IndexSyncError.notConfigured }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        _ = try await client.download(fileId: remote.fileId, to: tmp)
        var file = tmp
        if encrypted {
            let plain = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: tmp) }
            try FileCrypto.decrypt(input: tmp, output: plain, masterKey: try env.fileMasterKey())
            file = plain
        }
        return try cache.store(file: file, for: key, ext: ext)
    }

    /// Copies a cached original to a temp file with its real name (for sharing / saving).
    func shareableCopy(of url: URL, filename: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(filename.sanitizedFilename)
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }

    var cacheSizes: (thumbnails: Int64, originals: Int64) {
        (env.thumbnailCache.totalSize, env.originalsCache.totalSize)
    }

    func clearCaches() {
        memory.removeAllObjects()
        env.thumbnailCache.clear()
        env.originalsCache.clear()
    }
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
    private var tasks: [String: Task<URL, Error>] = [:]

    func run(_ key: String, _ body: @escaping @Sendable () async throws -> URL) async throws -> URL {
        if let existing = tasks[key] { return try await existing.value }
        let task = Task { try await body() }
        tasks[key] = task
        defer { tasks[key] = nil }
        return try await task.value
    }
}
