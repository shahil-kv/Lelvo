import Foundation
import CryptoKit
import LelvoCore

/// A problem the user can act on. One or two plain sentences.
struct ImportFailure: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum ImportPaths {
    static func fileName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// The folder that holds `path`, without a trailing slash.
    static func directory(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    static func child(_ root: URL, path: String) -> URL? {
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else { return nil }
        return parts.reduce(root) { $0.appendingPathComponent($1, isDirectory: false) }
    }
}

/// A zip or a folder of Takeout files. Listing is cheap for a zip (the central directory) and reads each file
/// once for a folder, because a folder has no stored CRC and the item key needs one.
protocol ImportSource: AnyObject, Sendable {
    var id: String { get }
    var name: String { get }
    /// `"zip"` or `"folder"`.
    var kind: String { get }
    /// The zip's size on disk. A folder is already unpacked, so this is 0.
    var byteCount: Int64 { get }
    func entries() throws -> [ZipEntry]
    @discardableResult
    func extract(_ entry: ZipEntry, to url: URL) throws -> String
    func data(_ entry: ZipEntry, limit: Int64) throws -> Data
}

enum OpenedImport {
    static func resolve(_ bookmark: Data) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &stale),
              (try? url.checkResourceIsReachable()) == true else { return nil }
        return url
    }

    /// Opens a file the user just chose. A `.tgz` export and anything that isn't a zip throw with what to do next.
    static func open(url: URL, id: String) throws -> any ImportSource {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let directory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        if directory { return FolderImportSource(id: id, name: url.lastPathComponent, url: url) }
        return try ZipImportSource(id: id, name: url.lastPathComponent, url: url)
    }

    static func open(record: ImportSourceRecord) -> (any ImportSource)? {
        guard let url = resolve(record.bookmark) else { return nil }
        let name = record.name
        if record.kind == "folder" { return FolderImportSource(id: record.id, name: name, url: url) }
        return try? ZipImportSource(id: record.id, name: name, url: url)
    }
}

final class ZipImportSource: ImportSource, @unchecked Sendable {
    let id: String
    let name: String
    let kind = "zip"
    let byteCount: Int64
    private let url: URL
    private let accessed: Bool
    private let archive: ZipArchive

    init(id: String, name: String, url: URL) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        let archive: ZipArchive
        do {
            archive = try ZipArchive(url: url)
        } catch {
            if accessed { url.stopAccessingSecurityScopedResource() }
            throw error
        }
        self.id = id
        self.name = name
        self.url = url
        self.accessed = accessed
        self.archive = archive
        self.byteCount = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    deinit {
        if accessed { url.stopAccessingSecurityScopedResource() }
    }

    func entries() throws -> [ZipEntry] { archive.entries }

    func extract(_ entry: ZipEntry, to url: URL) throws -> String {
        let fresh = archive.entries.first { $0.path == entry.path && $0.size == entry.size && $0.crc32 == entry.crc32 } ?? entry
        return try archive.extract(fresh, to: url)
    }

    func data(_ entry: ZipEntry, limit: Int64) throws -> Data {
        let fresh = archive.entries.first { $0.path == entry.path && $0.size == entry.size && $0.crc32 == entry.crc32 } ?? entry
        return try archive.data(fresh, limit: limit)
    }
}

final class FolderImportSource: ImportSource, @unchecked Sendable {
    let id: String
    let name: String
    let kind = "folder"
    let byteCount: Int64 = 0
    private let url: URL
    private let accessed: Bool
    private let lock = NSLock()
    private var cached: [ZipEntry]?

    init(id: String, name: String, url: URL) {
        self.id = id
        self.name = name
        self.url = url
        self.accessed = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if accessed { url.stopAccessingSecurityScopedResource() }
    }

    func entries() throws -> [ZipEntry] {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let scanned = try scan()
        cached = scanned
        return scanned
    }

    func extract(_ entry: ZipEntry, to dest: URL) throws -> String {
        guard let source = file(entry.path) else { throw ImportFailure("Lelvo skipped a file that sits outside the folder you chose.") }
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        guard fm.createFile(atPath: dest.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        do {
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: dest)
            defer { try? output.close() }
            var hasher = SHA256()
            var crc = CRC32()
            while true {
                let chunk = try input.read(upToCount: 1 << 20) ?? Data()
                if chunk.isEmpty { break }
                try output.write(contentsOf: chunk)
                hasher.update(data: chunk)
                crc.update(chunk)
            }
            guard crc.value == entry.crc32 else { throw ZipError.crcMismatch(entry.path) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch {
            try? fm.removeItem(at: dest)
            throw error
        }
    }

    func data(_ entry: ZipEntry, limit: Int64) throws -> Data {
        guard entry.size <= limit else { throw ZipError.tooLarge(entry.path) }
        guard let source = file(entry.path) else { throw ImportFailure("Lelvo skipped a file that sits outside the folder you chose.") }
        return try Data(contentsOf: source)
    }

    private func file(_ path: String) -> URL? {
        guard let child = ImportPaths.child(url, path: path) else { return nil }
        let root = url.standardizedFileURL.path
        let target = child.standardizedFileURL.path
        guard target == root || target.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { return nil }
        if (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { return nil }
        return child
    }

    private func scan() throws -> [ZipEntry] {
        let fm = FileManager.default
        let root = url.standardizedFileURL
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw ImportFailure("Lelvo can't read this folder. Choose it again.")
        }
        var entries: [ZipEntry] = []
        var unreadable = 0
        while let item = enumerator.nextObject() as? URL {
            let values = try? item.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if values?.isDirectory == true { continue }
            guard let relative = relativePath(of: item, under: root), let child = file(relative) else { continue }
            let size = Int64(values?.fileSize ?? 0)
            guard let crc = try? checksum(child) else { unreadable += 1; continue }
            entries.append(ZipEntry(path: relative, compressedSize: size, size: size, crc32: crc, method: 0,
                                    localHeaderOffset: 0, modified: values?.contentModificationDate))
        }
        if unreadable > 0 { appLog("Import couldn't read \(unreadable) files in a folder") }
        return entries
    }

    private func relativePath(of file: URL, under root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let path = file.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    private func checksum(_ file: URL) throws -> UInt32 {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var crc = CRC32()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            crc.update(chunk)
        }
        return crc.value
    }
}
