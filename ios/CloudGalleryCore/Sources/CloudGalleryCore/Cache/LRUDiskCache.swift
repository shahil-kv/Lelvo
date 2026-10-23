import Foundation

/// Size-capped disk cache with least-recently-used eviction. Lives in Caches/, so iOS may also purge it.
/// Access times are tracked in memory and persisted to a small JSON manifest.
public final class LRUDiskCache: @unchecked Sendable {
    public typealias Clock = () -> Date

    public let directory: URL
    public private(set) var capacity: Int64
    private let now: Clock
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var manifestURL: URL { directory.appendingPathComponent(".manifest.json") }

    struct Entry: Codable {
        var fileName: String
        var size: Int64
        var lastAccess: Date
    }

    public init(directory: URL, capacity: Int64, now: @escaping Clock = { Date() }) {
        self.directory = directory
        self.capacity = capacity
        self.now = now
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        loadManifest()
    }

    public var totalSize: Int64 {
        lock.lock(); defer { lock.unlock() }
        return entries.values.reduce(0) { $0 + $1.size }
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    public func setCapacity(_ bytes: Int64) {
        lock.lock()
        capacity = bytes
        evictLocked(keeping: nil)
        saveManifestLocked()
        lock.unlock()
    }

    static func fileName(for key: String, ext: String?) -> String {
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        let base = String(safe.prefix(120))
        guard let ext, !ext.isEmpty else { return base }
        return base + "." + ext
    }

    /// Returns the cached file and marks it as recently used.
    public func url(for key: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[key] else { return nil }
        let url = directory.appendingPathComponent(entry.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            entries[key] = nil
            return nil
        }
        entry.lastAccess = now()
        entries[key] = entry
        return url
    }

    public func contains(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entries[key] != nil
    }

    /// Moves `file` into the cache under `key`. The extension matters for AVPlayer/ImageIO.
    @discardableResult
    public func store(file: URL, for key: String, ext: String? = nil) throws -> URL {
        let fm = FileManager.default
        let name = Self.fileName(for: key, ext: ext ?? file.pathExtension)
        let dest = directory.appendingPathComponent(name)
        lock.lock(); defer { lock.unlock() }
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: file, to: dest)
        let size = ((try? fm.attributesOfItem(atPath: dest.path)[.size]) as? NSNumber)?.int64Value ?? 0
        entries[key] = Entry(fileName: name, size: size, lastAccess: now())
        evictLocked(keeping: key)
        saveManifestLocked()
        return dest
    }

    @discardableResult
    public func store(data: Data, for key: String, ext: String? = nil) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: tmp)
        return try store(file: tmp, for: key, ext: ext)
    }

    public func remove(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        if let e = entries.removeValue(forKey: key) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(e.fileName))
        }
        saveManifestLocked()
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            files.forEach { try? fm.removeItem(at: $0) }
        }
        entries.removeAll()
    }

    /// Persists access times; call when the app goes to the background.
    public func flush() {
        lock.lock(); defer { lock.unlock() }
        saveManifestLocked()
    }

    private func evictLocked(keeping protected: String?) {
        var total = entries.values.reduce(0) { $0 + $1.size }
        guard total > capacity else { return }
        let victims = entries.sorted { $0.value.lastAccess < $1.value.lastAccess }
        for (key, entry) in victims where total > capacity {
            if key == protected { continue }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.fileName))
            entries[key] = nil
            total -= entry.size
        }
    }

    private func loadManifest() {
        guard let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        let fm = FileManager.default
        entries = decoded.filter { fm.fileExists(atPath: directory.appendingPathComponent($0.value.fileName).path) }
    }

    private func saveManifestLocked() {
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: manifestURL, options: .atomic) }
    }
}
