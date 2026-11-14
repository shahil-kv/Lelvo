import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The temporary copies drag and Share hand to other apps. Another app can only take a real file, so each photo is
/// written out once, in a `Share-…` folder of its own. Only the latest drag is kept (a drop may still be reading it);
/// older ones are deleted at once, and leftovers when Lelvo starts. Copy keeps its files in `CopiedFiles` instead.
final class HandOffFiles: @unchecked Sendable {
    enum Kind: Sendable { case drag }

    static let shared = HandOffFiles()

    /// Copy stops below this much free space rather than fill the device with temporary copies.
    static let minimumFreeBytes: Int64 = 1 << 30

    private let lock = NSLock()
    private var kept: [Kind: [URL]] = [:]

    /// Keeps `files` as the latest of `kind` and deletes the ones before them.
    func replace(_ kind: Kind, with files: [URL]) {
        let old = lock.withLock { () -> [URL] in
            let old = kept[kind] ?? []
            kept[kind] = files
            return old
        }
        let keep = Set(files.map(Self.folder))
        for folder in Set(old.map(Self.folder)) where !keep.contains(folder) && Self.isOurs(folder) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Adds a file to the latest of `kind` (a drag's file is made only when the other app asks for it).
    func add(_ kind: Kind, _ file: URL) {
        lock.withLock { kept[kind, default: []].append(file) }
    }

    /// Whether there's room for more temporary copies.
    static func hasRoom() -> Bool {
        let values = try? FileManager.default.temporaryDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage else { return true }
        return free >= minimumFreeBytes
    }

    private var cleared = false

    /// Runs [clearLeftovers] once per launch (the apps call it each time they come to the front).
    func clearLeftoversOnce(keeping: Set<URL> = []) {
        let first = lock.withLock { () -> Bool in
            defer { cleared = true }
            return !cleared
        }
        guard first else { return }
        Self.clearLeftovers(keeping: keeping)
        CopiedFiles.prune()
    }

    /// At launch: every Copy, drag and share copy from before, except what's still on the clipboard (`keeping`) and
    /// anything written in the last few minutes (a share another app may still be reading).
    static func clearLeftovers(keeping: Set<URL> = []) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let found = (try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: keys)) ?? []
        let keep = Set(keeping.map(folder))
        var removed = 0
        for url in found where isOurs(url) && !keep.contains(url.standardizedFileURL) {
            let date = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
            guard Date().timeIntervalSince(date) > 5 * 60 else { continue }
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        if removed > 0 { appLog("Removed \(removed) leftover shared or copied file folder(s)") }
    }

    private static func folder(_ file: URL) -> URL { file.deletingLastPathComponent().standardizedFileURL }

    /// Only folders Lelvo made for sharing are ever deleted.
    private static func isOurs(_ folder: URL) -> Bool {
        folder.lastPathComponent.hasPrefix("Share-")
            && folder.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL
    }
}

/// Files Copy puts on the clipboard by reference (several photos, videos). They live in Lelvo's own Caches folder,
/// not temporary storage, so a clipboard manager's history keeps working for days, as with files copied in Finder.
/// Space is capped: the oldest go once the folder passes 2 GB or a copy is a week old. Clear Caches empties it.
enum CopiedFiles {
    static let maxBytes: Int64 = 2 << 30
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    static var folder: URL { AppPaths.caches.appendingPathComponent("Copied", isDirectory: true) }

    /// Moves prepared files (each in a `Share-…` folder of its own) into one new folder here; returns where they went.
    static func keep(_ files: [URL]) -> [URL] {
        let fm = FileManager.default
        let batch = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard (try? fm.createDirectory(at: batch, withIntermediateDirectories: true)) != nil else { return files }
        var kept: [URL] = []
        for file in files {
            var dest = batch.appendingPathComponent(file.lastPathComponent)
            var n = 1
            while fm.fileExists(atPath: dest.path) {
                n += 1
                dest = batch.appendingPathComponent("\(file.deletingPathExtension().lastPathComponent) \(n).\(file.pathExtension)")
            }
            if (try? fm.moveItem(at: file, to: dest)) != nil {
                try? fm.removeItem(at: file.deletingLastPathComponent())
                kept.append(dest)
            } else {
                kept.append(file)
            }
        }
        prune(keeping: batch)
        return kept
    }

    /// Deletes copies older than a week, then the oldest until the folder fits in 2 GB. `keeping`: the copy just made.
    static func prune(keeping: URL? = nil) {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let batches = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))) ?? [])
            .map { url -> (url: URL, date: Date, size: Int64) in
                let date = (try? url.resourceValues(forKeys: keys))?.contentModificationDate ?? .distantPast
                return (url, date, size(of: url))
            }
            .sorted { $0.date > $1.date }
        var total: Int64 = 0
        var removed = 0
        for batch in batches {
            let isNew = batch.url.standardizedFileURL == keeping?.standardizedFileURL
            let tooOld = Date().timeIntervalSince(batch.date) > maxAge
            if !isNew && (tooOld || total + batch.size > maxBytes) {
                if (try? fm.removeItem(at: batch.url)) != nil { removed += 1 }
            } else {
                total += batch.size
            }
        }
        if removed > 0 { appLog("Copied files: removed \(removed) old cop\(removed == 1 ? "y" : "ies"), \(Format.bytes(total)) kept") }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: folder)
    }

    private static func size(of folder: URL) -> Int64 {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        var total: Int64 = 0
        while let file = files?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

/// A photo on the clipboard as the picture itself, like Preview, Safari and Photos copy one: its own bytes (JPEG,
/// HEIC, PNG…), plus a JPEG when its own format isn't one every app reads (HEIC, RAW, TIFF). A clipboard manager saves
/// these bytes, so the photo pastes from its history even after Lelvo quits.
enum ClipboardImage {
    /// Photos bigger than this go by reference only (the clipboard holds everything in memory).
    static let maxBytes = 60 << 20

    static func representations(of file: URL) -> [(type: UTType, data: Data)] {
        guard let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image),
              let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxBytes,
              let data = try? Data(contentsOf: file) else { return [] }
        var out: [(UTType, Data)] = [(type, data)]
        if !type.conforms(to: .jpeg), !type.conforms(to: .png), let jpeg = jpeg(from: data) { out.append((.jpeg, jpeg)) }
        return out
    }

    /// Keeps the orientation and colour; drops nothing the eye would see (quality 0.92).
    private static func jpeg(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImageFromSource(dest, source, 0, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
