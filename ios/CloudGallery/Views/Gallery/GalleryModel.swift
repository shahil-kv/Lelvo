import Foundation
import Photos
import SwiftUI
import CloudGalleryCore

/// One tile in the unified timeline: a phone asset, a cloud item, or both.
struct GalleryEntry: Identifiable, Equatable, Hashable {
    let id: String
    let date: Date?
    let asset: PHAsset?
    let item: MediaItem?

    var isVideo: Bool { asset.map { $0.mediaType == .video } ?? (item?.kind == .video) }
    var isLive: Bool { asset.map { $0.mediaSubtypes.contains(.photoLive) } ?? (item?.kind == .livePhoto) }
    var duration: Double? { asset?.duration ?? item?.duration }
    var isCloudOnly: Bool { asset == nil }

    var badge: BackupBadge {
        guard let item else { return .phoneOnly }
        switch item.status {
        case .backedUp:
            if item.sizeClass == .uploadOnly { return .viewNeedsV2 }
            return asset == nil ? .cloudOnly : .backedUp
        case .tooLarge: return .tooLarge
        case .queued: return .waiting
        case .uploading: return .uploading
        case .failed: return .failed
        }
    }

    var accessibilityLabel: String {
        let kind = isVideo ? "Video" : (isLive ? "Live Photo" : "Photo")
        return "\(kind), \(Format.date(date, style: .long, time: .short)), \(badge.label)"
    }

    static func == (a: GalleryEntry, b: GalleryEntry) -> Bool { a.id == b.id && a.item == b.item && a.asset == b.asset }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// What a grid shows: the whole timeline, or a smart/device album.
enum GalleryFilter: Hashable {
    case videos, livePhotos, favorites, cloudOnly, notBackedUp
    case album(title: String, localIds: Set<String>)

    var title: String {
        switch self {
        case .videos: return "Videos"
        case .livePhotos: return "Live Photos"
        case .favorites: return "Favorites"
        case .cloudOnly: return "Only in the cloud"
        case .notBackedUp: return "Not backed up"
        case .album(let t, _): return t
        }
    }

    func matches(_ e: GalleryEntry) -> Bool {
        switch self {
        case .videos: return e.isVideo
        case .livePhotos: return e.isLive
        case .favorites: return e.asset?.isFavorite == true || e.item?.favorite == true
        case .cloudOnly: return e.isCloudOnly
        case .notBackedUp: return [.phoneOnly, .waiting, .failed].contains(e.badge)
        case .album(let title, let ids):
            return e.asset.map { ids.contains($0.localIdentifier) } == true || e.item?.albums?.contains(title) == true
        }
    }
}

struct GallerySection: Identifiable {
    let id: String
    let title: String
    let entries: [GalleryEntry]
}

@MainActor
final class GalleryModel: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published private(set) var sections: [GallerySection] = []
    @Published private(set) var entries: [GalleryEntry] = []
    @Published private(set) var loaded = false
    /// Bumped on every reload, so views can recompute derived data without comparing entries.
    @Published private(set) var revision = 0
    /// Bumped whenever `sections` changes (reload or regrouping), for views that mirror them.
    @Published private(set) var sectionsRevision = 0
    @Published var authorization = PhotoLibraryService.authorizationStatus

    private let env = AppEnvironment.shared
    private var reloadTask: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private var grouping: Grouping = .day

    enum Grouping: Equatable {
        case day, month, year
        /// Denser grids group more coarsely, like Photos.
        init(columns: Int) { self = columns >= 8 ? .year : (columns >= 6 ? .month : .day) }
    }

    private var availabilityObserver: NSObjectProtocol?
    private var registered = false

    override init() {
        super.init()
        observer = NotificationCenter.default.addObserver(forName: LibraryStore.didChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleReload() }
        }
        // Photos answering (or not) changes what the timeline can show.
        availabilityObserver = NotificationCenter.default.addObserver(forName: PhotoAvailability.didChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.registerForChangesIfNeeded()
                await self?.reload()
            }
        }
        PhotoAvailability.probeIfNeeded()
        registerForChangesIfNeeded()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let availabilityObserver { NotificationCenter.default.removeObserver(availabilityObserver) }
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in self.scheduleReload() }
    }

    func setGrouping(_ g: Grouping) {
        guard g != grouping else { return }
        grouping = g
        sections = Self.group(entries, grouping: g)
        sectionsRevision += 1
    }

    /// Throttled, not debounced: during a backup the store changes every second, and a debounce would keep
    /// postponing the reload; this reloads at most every 1.5 s and never starves.
    func scheduleReload() {
        guard reloadTask == nil else { return }
        reloadTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            reloadTask = nil
            guard !Task.isCancelled else { return }
            await reload()
        }
    }

    func reload() async {
        authorization = PhotoLibraryService.authorizationStatus
        let env = self.env
        let grouping = self.grouping
        let old = loaded ? self.entries : nil
        let result = await Task.detached(priority: .userInitiated) { () -> ([GalleryEntry], [GallerySection])? in
            let assets: PHFetchResult<PHAsset>? = PhotoLibraryService.hasAccess ? env.photos.fetchAllAssets() : nil
            let items = (try? env.store.allItems()) ?? []
            let merged = Self.merge(assets: assets, items: items)
            // Nothing visible changed (e.g. an upload checkpoint): keep the grid as it is, no re-render.
            if let old, old == merged { return nil }
            return (merged, Self.group(merged, grouping: grouping))
        }.value
        guard let (entries, sections) = result else { return }
        self.entries = entries
        self.sections = sections
        revision += 1
        sectionsRevision += 1
        loaded = true
    }

    nonisolated static func merge(assets: PHFetchResult<PHAsset>?, items: [MediaItem]) -> [GalleryEntry] {
        var byLocal: [String: MediaItem] = [:]
        for item in items { if let id = item.localIdentifier, byLocal[id] == nil { byLocal[id] = item } }

        var local: [GalleryEntry] = []
        var present = Set<String>()
        assets?.enumerateObjects { asset, _, _ in
            present.insert(asset.localIdentifier)
            local.append(GalleryEntry(id: asset.localIdentifier, date: asset.creationDate, asset: asset,
                                      item: byLocal[asset.localIdentifier]))
        }
        // Cloud-only: confirmed uploads whose asset is not on this phone (deleted, restored, other device).
        let cloud = items
            .filter { ($0.status == .backedUp) && ($0.localIdentifier.map { !present.contains($0) } ?? true) }
            .map { GalleryEntry(id: "cloud-\($0.id)", date: $0.creationDate, asset: nil, item: $0) }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }

        // Both lists are newest-first; merge them.
        var out: [GalleryEntry] = []
        out.reserveCapacity(local.count + cloud.count)
        var i = 0, j = 0
        while i < local.count || j < cloud.count {
            if j >= cloud.count || (i < local.count && (local[i].date ?? .distantPast) >= (cloud[j].date ?? .distantPast)) {
                out.append(local[i]); i += 1
            } else {
                out.append(cloud[j]); j += 1
            }
        }
        return out
    }

    nonisolated static func group(_ entries: [GalleryEntry], grouping: Grouping) -> [GallerySection] {
        let cal = Calendar.current
        let dayFormatter = DateFormatter()
        dayFormatter.setLocalizedDateFormatFromTemplate("EEE d MMM yyyy")
        let monthFormatter = DateFormatter()
        monthFormatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")

        var sections: [GallerySection] = []
        var currentKey: String?
        var currentTitle = ""
        var bucket: [GalleryEntry] = []
        for entry in entries {
            let key: String
            var title = currentTitle
            if let date = entry.date {
                let c = cal.dateComponents([.year, .month, .day], from: date)
                let y = c.year ?? 0, m = c.month ?? 0, d = c.day ?? 0
                switch grouping {
                case .day: key = "\(y)-\(m)-\(d)"
                case .month: key = "\(y)-\(m)"
                case .year: key = "\(y)"
                }
                if key != currentKey {
                    switch grouping {
                    case .day:
                        if cal.isDateInToday(date) { title = "Today" }
                        else if cal.isDateInYesterday(date) { title = "Yesterday" }
                        else { title = dayFormatter.string(from: date) }
                    case .month: title = monthFormatter.string(from: date)
                    case .year: title = String(y)
                    }
                }
            } else {
                key = "unknown"
                title = "Unknown date"
            }
            if key != currentKey {
                if let currentKey, !bucket.isEmpty { sections.append(GallerySection(id: currentKey, title: currentTitle, entries: bucket)) }
                currentKey = key
                currentTitle = title
                bucket = []
            }
            bucket.append(entry)
        }
        if let currentKey, !bucket.isEmpty { sections.append(GallerySection(id: currentKey, title: currentTitle, entries: bucket)) }
        // Undated items may appear in several runs; keep section ids unique for ScrollViewReader.
        var seen = Set<String>()
        return sections.map { s in
            var id = s.id
            var n = 1
            while !seen.insert(id).inserted { n += 1; id = "\(s.id)#\(n)" }
            return GallerySection(id: id, title: s.title, entries: s.entries)
        }
    }

    /// Off the main thread: registering opens the photo library, which can take a while.
    func registerForChangesIfNeeded() {
        PhotoAvailability.probeIfNeeded()
        guard !registered, PhotoLibraryService.hasAccess else { return }
        registered = true
        Task.detached(priority: .utility) { PHPhotoLibrary.shared().register(self) }
    }
}
