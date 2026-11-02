import Foundation

/// "Keep a second copy": which files of the library belong in the user's own folder (an external drive, a NAS), where
/// they go, and which are still missing. Pure logic; the app's `SecondCopyService` does the downloading.
///
/// Layout matches Download a copy: `Year/Month/filename`, plus `name (edited).ext` and the Live Photo video. What was
/// copied is recorded per item and role in a manifest kept in the folder, so a drive that comes back, or a second
/// item with the same name and size, never gets guessed from file names.
public enum SecondCopy {
    /// One file the folder should hold.
    public struct File: Equatable, Sendable {
        public var itemId: String
        /// Caption role: `o` original, `pv` Live Photo video, `e` edited version.
        public var role: String
        /// Relative to the folder, with `/` separators.
        public var path: String
        /// Expected size in bytes; 0 when the index doesn't know it (very old items).
        public var size: Int64
        public var date: Date?

        public init(itemId: String, role: String, path: String, size: Int64, date: Date?) {
            self.itemId = itemId; self.role = role; self.path = path; self.size = size; self.date = date
        }

        public var key: String { Manifest.key(itemId, role) }
    }

    /// What has been copied, saved as a hidden file in the folder so it travels with the drive.
    /// Holds item ids, roles, relative paths and sizes only.
    public struct Manifest: Codable, Equatable, Sendable {
        public static let fileName = ".lelvo-second-copy.json"

        public struct Entry: Codable, Equatable, Sendable {
            public var path: String
            public var size: Int64
            public init(path: String, size: Int64) { self.path = path; self.size = size }
        }

        public var version = 1
        /// Keyed by `itemId/role`.
        public var files: [String: Entry] = [:]

        public init() {}

        public static func key(_ itemId: String, _ role: String) -> String { "\(itemId)/\(role)" }

        public mutating func record(_ file: File, size: Int64) {
            files[file.key] = Entry(path: file.path, size: size)
        }

        /// Item ids with at least one copied file.
        public var itemIds: Set<String> {
            Set(files.keys.compactMap { $0.split(separator: "/", maxSplits: 1).first.map(String.init) })
        }
    }

    public struct Plan: Equatable, Sendable {
        /// Missing or incomplete in the folder: download these.
        public var toCopy: [File] = []
        /// Already in the folder with the right size but not in the manifest yet (a folder used for Download a copy
        /// before, or a manifest lost to a crash): record them, don't download again.
        public var toAdopt: [File] = []
        /// Files the folder already holds, per the manifest and the size on disk.
        public var upToDate = 0
        public var upToDateBytes: Int64 = 0
        /// Items copied earlier that are no longer in the library. Their files stay in the folder.
        public var removedFromLibrary = 0

        public var bytesToCopy: Int64 { toCopy.reduce(0) { $0 + $1.size } }
    }

    /// The files an item should have in the folder, before collisions are resolved.
    public static func wanted(_ item: MediaItem, calendar: Calendar) -> [File] {
        let folder = monthFolder(item.creationDate, calendar: calendar)
        var files = [File(itemId: item.id, role: "o", path: folder + sanitized(item.filename), size: item.fileSize, date: item.creationDate)]
        let base = (item.filename as NSString).deletingPathExtension
        if item.kind == .livePhoto, !item.parts("pv").isEmpty {
            let name = item.pairedVideoFilename ?? "\(base).MOV"
            files.append(File(itemId: item.id, role: "pv", path: folder + sanitized(name), size: item.pairedVideoSize ?? 0, date: item.creationDate))
        }
        if item.hasEdit == true, !item.parts("e").isEmpty {
            let ext = ((item.editedFilename ?? item.filename) as NSString).pathExtension
            let name = ext.isEmpty ? "\(base) (edited)" : "\(base) (edited).\(ext)"
            files.append(File(itemId: item.id, role: "e", path: folder + sanitized(name), size: item.editedSize ?? 0, date: item.creationDate))
        }
        return files
    }

    /// What to do to bring the folder in step with `items` (the library's backed-up items).
    /// `sizeOnDisk` returns a relative path's size, or nil if nothing is there.
    public static func plan(items: [MediaItem], manifest: Manifest, calendar: Calendar,
                            sizeOnDisk: (String) -> Int64?) -> Plan {
        var plan = Plan()
        // Paths the manifest already gives to an item, so a new item never takes one.
        var claimed: [String: String] = [:]
        for (key, entry) in manifest.files where isSafe(entry.path) { claimed[entry.path.lowercased()] = key }

        let present = Set(items.map(\.id))
        plan.removedFromLibrary = manifest.itemIds.subtracting(present).count

        for item in items.sorted(by: { ($0.creationDate ?? .distantPast, $0.id) < ($1.creationDate ?? .distantPast, $1.id) }) {
            for var file in wanted(item, calendar: calendar) {
                // The manifest sits on a drive or share others can write to, so its paths aren't trusted: one that could
                // leave the folder is ignored, and the file gets a normal path below.
                if let entry = manifest.files[file.key], isSafe(entry.path) {
                    file.path = entry.path
                    guard let onDisk = sizeOnDisk(entry.path) else {
                        // Gone (deleted by hand, a new drive): copy it again to the same place.
                        plan.toCopy.append(file)
                        continue
                    }
                    if onDisk == entry.size {
                        plan.upToDate += 1
                        plan.upToDateBytes += onDisk
                        continue
                    }
                    // A different size from what was written means something else changed it, say an edit saved in
                    // Preview (Lelvo writes to a partial file and moves it, so it never leaves a short file here).
                    // Nothing is ever deleted from the copy: leave it and copy to a new path.
                    var others = claimed
                    others[entry.path.lowercased()] = changedOutsideLelvo
                    file.path = freePath(for: file, claimed: others, sizeOnDisk: sizeOnDisk)
                    claimed[file.path.lowercased()] = file.key
                    plan.toCopy.append(file)
                    continue
                }
                file.path = freePath(for: file, claimed: claimed, sizeOnDisk: sizeOnDisk)
                claimed[file.path.lowercased()] = file.key
                if file.size > 0, sizeOnDisk(file.path) == file.size {
                    plan.toAdopt.append(file)
                } else {
                    plan.toCopy.append(file)
                }
            }
        }
        return plan
    }

    /// Owner of a path whose file was changed outside Lelvo: it's taken, whoever the manifest says wrote it.
    public static let changedOutsideLelvo = "changed-outside-lelvo"

    /// A path that stays inside the folder: relative, with no `.`, `..` or empty parts. This is only a check of the
    /// text; the app also refuses paths that go through a symbolic link before it writes.
    public static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\\"), !path.contains("\0") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// The wanted path, or `name-<id>.ext` when another item owns that path, or a different file of ours (or the
    /// user's) already sits there. Case-insensitive, because macOS and most drives are.
    public static func freePath(for file: File, claimed: [String: String], sizeOnDisk: (String) -> Int64?) -> String {
        func taken(_ path: String) -> Bool {
            if let owner = claimed[path.lowercased()] { return owner != file.key }
            if let onDisk = sizeOnDisk(path) { return file.size == 0 || onDisk != file.size }
            return false
        }
        guard taken(file.path) else { return file.path }
        let ns = file.path as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        let suffix = file.role == "o" ? String(file.itemId.prefix(6)) : "\(file.itemId.prefix(6))-\(file.role)"
        var candidate = ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"
        var n = 2
        while taken(candidate) {
            candidate = ext.isEmpty ? "\(stem)-\(suffix)-\(n)" : "\(stem)-\(suffix)-\(n).\(ext)"
            n += 1
        }
        return candidate
    }

    static func monthFolder(_ date: Date?, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month], from: date ?? Date(timeIntervalSince1970: 0))
        return String(format: "%04d/%02d/", c.year ?? 1970, c.month ?? 1)
    }

    /// A file name that is safe on macOS, Windows-formatted drives and NAS shares.
    public static func sanitized(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r")).joined(separator: "_")
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        // A leading dot would hide the file.
        let visible = trimmed.hasPrefix(".") ? "_" + trimmed.dropFirst() : trimmed
        return visible.isEmpty ? "file" : visible
    }
}
