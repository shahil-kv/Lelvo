import Foundation

/// A file in one of the added zips or folders.
public struct TakeoutSourceEntry: Sendable, Equatable, Hashable, Codable {
    public var sourceId: String
    public var entry: ZipEntry

    public init(sourceId: String, entry: ZipEntry) {
        self.sourceId = sourceId
        self.entry = entry
    }
}

/// Where an item's capture date will come from, before the file is read. The date that was written is `dateUsed`.
public enum DateSource: String, Sendable, Codable {
    /// Google's JSON file.
    case google
    /// The file itself (EXIF or the video's creation date); the importer moves the item to waiting if it has none.
    case fileWillTell
    /// Neither yet: its JSON file may be in a zip that hasn't been added.
    case waiting
}

/// One item to upload: a photo, video or Live Photo, with everything Google knew about it.
public struct TakeoutPlannedItem: Sendable, Equatable, Codable {
    /// Stable across runs: the primary file's name (without Google's `(1)`), size and CRC-32.
    public var key: String
    public var kind: MediaKind
    public var primary: TakeoutSourceEntry
    public var pairedVideo: TakeoutSourceEntry?
    public var edited: TakeoutSourceEntry?
    /// The same files in other folders (album copies). Never uploaded; a zip is finished only when these are too.
    public var copies: [TakeoutSourceEntry]
    public var albums: [String]
    public var sidecar: TakeoutSidecar?
    public var dateSource: DateSource
    /// Set once the file has been read, and kept in the import index so the result list still works after a relaunch.
    public var dateUsed: TakeoutDateChoice.Source? = nil
}

/// Albums and favourite for an item imported in an earlier run (an album copy that came in a later zip).
public struct TakeoutLateDetail: Sendable, Equatable {
    public var key: String
    public var albums: [String]
    public var favorite: Bool

    public init(key: String, albums: [String], favorite: Bool) {
        self.key = key
        self.albums = albums
        self.favorite = favorite
    }
}

public struct TakeoutPlan: Sendable {
    public var items: [TakeoutPlannedItem] = []
    /// Files that aren't photos or videos: counted and listed, never uploaded.
    public var skipped: [TakeoutSourceEntry] = []
    public var lateDetails: [TakeoutLateDetail] = []
    /// Every photo and video file and the item it belongs to, so a zip can be called finished file by file.
    public var entryKeys: [TakeoutSourceEntry: String] = [:]
    public var photoCount: Int { items.filter { $0.kind != .video }.count }
    public var videoCount: Int { items.filter { $0.kind == .video }.count }
}

/// Turns the files of a Takeout into items: one per photo however many album folders it's in, Live Photos paired,
/// edited copies attached to their original, and each matched to Google's JSON file.
public enum TakeoutPlanner {
    /// - Parameters:
    ///   - entries: every file of every added source, in the order the sources were added.
    ///   - sidecars: Google's JSON files by path, from any source (a JSON file can be in another zip than its photo).
    ///   - albumTitles: folder path → title from the folder's `metadata.json`.
    ///   - alreadyImportedKeys: items whose upload started or finished; their shape (Live Photo, edit) can't change.
    public static func plan(entries: [TakeoutSourceEntry], sidecars: [String: TakeoutSidecar],
                            albumTitles: [String: String], allFilesAdded: Bool,
                            alreadyImportedKeys: Set<String> = []) -> TakeoutPlan {
        var plan = TakeoutPlan()

        // 1. Copies of the same file across folders become one group.
        var order: [String] = []
        var groups: [String: [TakeoutSourceEntry]] = [:]
        var groupByPath: [String: String] = [:]
        for source in entries {
            switch TakeoutMatcher.kind(ofPath: source.entry.path) {
            case .photo, .video:
                let key = key(for: source.entry)
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append(source)
                groupByPath[TakeoutMatcher.normalized(source.entry.path)] = key
            case .other:
                plan.skipped.append(source)
            case .sidecar, .albumMetadata:
                break
            }
        }

        let albums = Dictionary(albumTitles.compactMap { folder, title -> (String, String)? in
            let name = TakeoutMatcher.fileName(folder.hasSuffix("/") ? String(folder.dropLast()) : folder)
            guard !isYearFolder(name), !isYearFolder(title) else { return nil }
            return (folderKey(folder), title)
        }, uniquingKeysWith: { a, _ in a })
        let sidecarFinder = SidecarFinder(sidecars)

        // 2. Live Photos: a still and a .MOV with the same name in the same folder.
        var consumedBy: [String: String] = [:]
        var pairedVideo: [String: String] = [:]
        var edited: [String: String] = [:]
        var stills: [String: String] = [:]
        for key in order where !alreadyImportedKeys.contains(key) {
            for copy in groups[key]! where livePhotoStillExtensions.contains(ext(copy.entry.path)) {
                stills[stemKey(copy.entry.path)] = stills[stemKey(copy.entry.path)] ?? key
            }
        }
        for key in order where !alreadyImportedKeys.contains(key) {
            guard let copies = groups[key], copies.allSatisfy({ ext($0.entry.path) == "mov" }) else { continue }
            let still = copies.lazy.compactMap { stills[stemKey($0.entry.path)] }.first { pairedVideo[$0] == nil }
            if let still {
                pairedVideo[still] = key
                consumedBy[key] = still
            }
        }

        // 3. Edited copies: `IMG_1-edited.jpg` goes with `IMG_1.jpg` when both are new.
        for key in order where !alreadyImportedKeys.contains(key) && consumedBy[key] == nil && pairedVideo[key] == nil {
            for copy in groups[key]! where TakeoutMatcher.kind(ofPath: copy.entry.path) == .photo {
                guard let originalPath = TakeoutMatcher.originalPath(ofEditedPath: copy.entry.path),
                      let original = groupByPath[TakeoutMatcher.normalized(originalPath)], original != key,
                      !alreadyImportedKeys.contains(original), consumedBy[original] == nil, edited[original] == nil
                else { continue }
                edited[original] = key
                consumedBy[key] = original
                break
            }
        }

        // 4. Items.
        for key in order where consumedBy[key] == nil {
            let own = groups[key]!
            let video = pairedVideo[key].flatMap { groups[$0] }
            let edit = edited[key].flatMap { groups[$0] }
            let all = own + (video ?? []) + (edit ?? [])
            for copy in all { plan.entryKeys[copy] = key }

            let titles = Set(all.compactMap { albums[folderKey(TakeoutMatcher.split($0.entry.path).dir)] }).sorted()
            let sidecar = own.lazy.compactMap { sidecarFinder.find(forMediaPath: $0.entry.path) }.first
                ?? (edit ?? []).lazy.compactMap { sidecarFinder.find(forMediaPath: $0.entry.path) }.first

            if alreadyImportedKeys.contains(key) {
                plan.lateDetails.append(TakeoutLateDetail(key: key, albums: titles, favorite: sidecar?.favorite ?? false))
                continue
            }
            let primary = own[0]
            let dateSource: DateSource
            if sidecar?.takenAt != nil {
                dateSource = .google
            } else if allFilesAdded || dateBearingExtensions.contains(ext(primary.entry.path)) {
                dateSource = .fileWillTell
            } else {
                dateSource = .waiting
            }
            let isVideo = TakeoutMatcher.kind(ofPath: primary.entry.path) == .video
            plan.items.append(TakeoutPlannedItem(
                key: key, kind: isVideo ? .video : (video != nil ? .livePhoto : .photo), primary: primary,
                pairedVideo: video?.first, edited: edit?.first,
                copies: Array(own.dropFirst()) + (video?.dropFirst() ?? []) + (edit?.dropFirst() ?? []),
                albums: titles, sidecar: sidecar, dateSource: dateSource))
        }
        return plan
    }

    /// A Live Photo video or an edited copy whose other half was already imported. It uploads as its own item.
    /// The zip it came from names it before that zip can be deleted, so the split isn't silent.
    public static func importedSeparately(_ items: [TakeoutPlannedItem], alreadyImported: [TakeoutPlannedItem]) -> [TakeoutSourceEntry] {
        var stillStems = Set<String>()
        var paths = Set<String>()
        for item in alreadyImported {
            for file in files(of: item) {
                paths.insert(TakeoutMatcher.normalized(file.entry.path))
                if livePhotoStillExtensions.contains(ext(file.entry.path)) {
                    stillStems.insert(stemKey(file.entry.path))
                }
            }
        }
        var separate: [TakeoutSourceEntry] = []
        for item in items {
            let own = files(of: item)
            let splitVideo = ext(item.primary.entry.path) == "mov"
                && own.contains { stillStems.contains(stemKey($0.entry.path)) }
            // Only the item whose own file is the edited copy. An original that already has its edit attached
            // is one item, and naming it here would tell the user it was split.
            let splitEdit = TakeoutMatcher.originalPath(ofEditedPath: item.primary.entry.path)
                .map { paths.contains(TakeoutMatcher.normalized($0)) } ?? false
            if splitVideo || splitEdit { separate.append(contentsOf: own) }
        }
        return separate
    }

    private static func files(of item: TakeoutPlannedItem) -> [TakeoutSourceEntry] {
        var all = [item.primary]
        if let paired = item.pairedVideo { all.append(paired) }
        if let edited = item.edited { all.append(edited) }
        all.append(contentsOf: item.copies)
        return all
    }

    public static func key(for entry: ZipEntry) -> String {
        let name = TakeoutMatcher.splitDuplicate(TakeoutMatcher.fileName(entry.path)).plain
        return "\(TakeoutMatcher.normalized(name))|\(entry.size)|\(String(entry.crc32, radix: 16))"
    }

    static let livePhotoStillExtensions: Set<String> = ["heic", "heif", "jpg", "jpeg"]
    /// Files that normally carry their own capture date.
    static let dateBearingExtensions: Set<String> = ["heic", "heif", "jpg", "jpeg", "dng", "cr2", "cr3", "nef", "arw",
                                                     "orf", "rw2", "raf", "srw", "tif", "tiff", "mov", "mp4", "m4v", "3gp"]

    /// Google's year folders ("Photos from 2019"), localised. Newer exports give them a `metadata.json` too, so the
    /// file alone doesn't make a folder an album.
    static func isYearFolder(_ name: String) -> Bool {
        name.range(of: #"^(photos from|fotos von|photos de|fotos de|foto dal|foto's uit|fotos från|fotos fra|zdjęcia z|fotky z|фото за) (19|20)\d\d$"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func ext(_ path: String) -> String {
        (TakeoutMatcher.fileName(path) as NSString).pathExtension.lowercased()
    }

    static func folderKey(_ path: String) -> String {
        TakeoutMatcher.normalized(path.hasSuffix("/") ? String(path.dropLast()) : path)
    }

    /// Folder and file name without its extension: `IMG_1.HEIC` and `IMG_1.MOV` share it.
    static func stemKey(_ path: String) -> String {
        let normalized = TakeoutMatcher.normalized(path)
        let ext = (normalized as NSString).pathExtension
        return ext.isEmpty ? normalized : String(normalized.dropLast(ext.count + 1))
    }
}

/// Finds a photo's JSON file by Google's naming rules, falling back to the `title` inside the JSON for names Google cut.
struct SidecarFinder {
    private let byPath: [String: TakeoutSidecar]
    /// Folder → (title, sidecar), for the fallback.
    private let byFolder: [String: [(title: String, sidecar: TakeoutSidecar)]]

    init(_ sidecars: [String: TakeoutSidecar]) {
        var byPath: [String: TakeoutSidecar] = [:]
        var byFolder: [String: [(title: String, sidecar: TakeoutSidecar)]] = [:]
        for (path, sidecar) in sidecars {
            byPath[TakeoutMatcher.normalized(path)] = sidecar
            if let title = sidecar.title, !title.isEmpty {
                byFolder[TakeoutPlanner.folderKey(TakeoutMatcher.split(path).dir), default: []]
                    .append((TakeoutMatcher.normalized(title), sidecar))
            }
        }
        self.byPath = byPath
        self.byFolder = byFolder
    }

    func find(forMediaPath path: String) -> TakeoutSidecar? {
        for candidate in TakeoutMatcher.sidecarCandidates(forMediaPath: path) {
            if let found = byPath[TakeoutMatcher.normalized(candidate)] { return found }
        }
        let (dir, name) = TakeoutMatcher.split(path)
        guard let inFolder = byFolder[TakeoutPlanner.folderKey(dir)] else { return nil }
        let wanted = TakeoutMatcher.normalized(TakeoutMatcher.splitDuplicate(name).plain)
        // Only an unambiguous title counts: two JSON files claiming the same name would be a guess.
        let exact = inFolder.filter { $0.title == wanted }
        if exact.count == 1 { return exact[0].sidecar }
        guard exact.isEmpty, wanted.count >= 40 else { return nil }
        let ext = (wanted as NSString).pathExtension
        let stem = ext.isEmpty ? wanted : String(wanted.dropLast(ext.count + 1))
        let cut = inFolder.filter { ($0.title as NSString).pathExtension == ext && $0.title.hasPrefix(stem) }
        return cut.count == 1 ? cut[0].sidecar : nil
    }
}
