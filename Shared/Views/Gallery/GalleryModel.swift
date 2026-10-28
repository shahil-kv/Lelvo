import Foundation
import Photos
import SwiftUI
import MemvoCore

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
        // Deleted from the cloud: only the phone copy is left.
        case .trashed: return .phoneOnly
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
    private let source = TimelineSource()
    private var reloadTask: Task<Void, Never>?
    /// Changes waiting for the next throttled refresh (see `scheduleReload`).
    private var pending = TimelineSource.Changes()
    /// One refresh at a time: each compares against what the one before it showed.
    private var refreshing = false, refreshAgain = false
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
        observer = NotificationCenter.default.addObserver(forName: LibraryStore.didChange, object: nil, queue: .main) { [weak self] note in
            let ids = LibraryStore.changedIds(note)
            Task { @MainActor in
                guard let self else { return }
                if let ids { self.pending.itemIds.formUnion(ids) } else { self.pending.everything = true }
                self.scheduleReload()
            }
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
        Task { @MainActor in
            pending.photoChanges.append(changeInstance)
            scheduleReload()
        }
    }

    /// Regroups off the main thread (a pinch must not stall the first scroll after it).
    func setGrouping(_ g: Grouping) {
        guard g != grouping else { return }
        grouping = g
        let entries = self.entries
        Task {
            let sections = await Task.detached(priority: .userInitiated) { Self.group(entries, grouping: g) }.value
            guard self.grouping == g else { return }
            self.sections = sections
            sectionsRevision += 1
        }
    }

    /// Throttled, not debounced: during a backup the store changes every second, and a debounce would keep
    /// postponing the reload; this reloads at most every 1.5 s and never starves.
    func scheduleReload() {
        guard reloadTask == nil else { return }
        // First change after a quiet moment shows almost at once (e.g. green ticks after linking); during a busy
        // backup, reloads are spaced 1.5 s apart.
        let wait = max(0.15, 1.5 - Date().timeIntervalSince(lastReload))
        reloadTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            reloadTask = nil
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    private var lastReload = Date.distantPast

    /// Reads the whole photo library and store again (first load, photo access changed, pull to refresh).
    func reload() async {
        pending.everything = true
        await refresh()
    }

    /// Applies the pending changes. During a backup these are a few item ids each time, so only those items are read
    /// from the store, and the photo list is patched from Photos' change details instead of being read again.
    private func refresh() async {
        refreshAgain = true
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        while refreshAgain {
            refreshAgain = false
            await refreshOnce()
        }
    }

    private func refreshOnce() async {
        lastReload = Date()
        authorization = PhotoLibraryService.authorizationStatus
        var changes = pending
        pending = TimelineSource.Changes()
        if !loaded { changes.everything = true }
        let grouping = self.grouping
        let old = loaded ? (entries: self.entries, sections: self.sections) : nil
        let source = self.source
        let started = Date()
        let result = await Task.detached(priority: .userInitiated) { () -> ([GalleryEntry], [GallerySection])? in
            let merged = await source.entries(applying: changes)
            // Nothing visible changed (e.g. an upload checkpoint): keep the grid as it is, no re-render.
            if let old, old.entries == merged { return nil }
            let sections = old.flatMap { Self.sections($0.sections, refilledFrom: $0.entries, with: merged) }
            return (merged, sections ?? Self.group(merged, grouping: grouping))
        }.value
        // Slow refreshes are what made the timeline stutter during backups in large libraries (#25).
        let took = Date().timeIntervalSince(started)
        if changes.everything || took > 0.1 {
            appLog(String(format: "Timeline refresh (%@) took %.0f ms for %d entries", changes.everything ? "full" : "changes",
                          took * 1000, result?.0.count ?? self.entries.count))
        }
        guard let (entries, sections) = result else { return }
        self.entries = entries
        self.sections = sections
        revision += 1
        sectionsRevision += 1
        loaded = true
    }

    /// The same sections with updated entries, when only the entries' contents changed (an upload finished, a badge
    /// changed): same ids in the same order with the same dates, so every section boundary stays where it is.
    /// Nil when anything moved, appeared or went; the caller then groups from scratch.
    nonisolated static func sections(_ sections: [GallerySection], refilledFrom old: [GalleryEntry],
                                     with new: [GalleryEntry]) -> [GallerySection]? {
        guard old.count == new.count, sections.reduce(0, { $0 + $1.entries.count }) == new.count else { return nil }
        for (a, b) in zip(old, new) where a.id != b.id || a.date != b.date { return nil }
        var start = 0
        return sections.map { s in
            defer { start += s.entries.count }
            return GallerySection(id: s.id, title: s.title, entries: Array(new[start..<start + s.entries.count]))
        }
    }

    /// `aliases`: photos that are copies of a backed-up item show that item's badge instead of looking unknown.
    nonisolated static func merge(assets: [PHAsset], items: OrderedItems, aliases: [String: String] = [:]) -> [GalleryEntry] {
        var local: [GalleryEntry] = []
        local.reserveCapacity(assets.count)
        var present = Set<String>()
        /// Items with a photo on this device, its own or a copy of it.
        var onPhone = Set<String>()
        for asset in assets {
            present.insert(asset.localIdentifier)
            let item = items.item(localIdentifier: asset.localIdentifier) ?? aliases[asset.localIdentifier].flatMap { items.item(id: $0) }
            if let item { onPhone.insert(item.id) }
            local.append(GalleryEntry(id: asset.localIdentifier, date: asset.creationDate, asset: asset, item: item))
        }
        // Cloud-only: confirmed uploads whose asset is not on this phone (deleted, restored, other device).
        // `items` is newest first already (`OrderedItems`), so this list needs no sorting.
        let cloud = items.items
            // Hidden in Photos: never shown here (they're in the backup and come back hidden).
            .filter { ($0.status == .backedUp) && $0.hidden != true && !onPhone.contains($0.id)
                && ($0.localIdentifier.map { !present.contains($0) } ?? true) }
            .map { GalleryEntry(id: "cloud-\($0.id)", date: $0.creationDate, asset: nil, item: $0) }

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

/// The timeline's copy of the photo list and the store, kept between refreshes so a change costs only what changed.
actor TimelineSource {
    struct Changes {
        /// Read everything again.
        var everything = false
        var itemIds = Set<String>()
        var photoChanges: [PHChange] = []
    }

    private var fetch: PHFetchResult<PHAsset>?
    private var assets: [PHAsset] = []
    private var items = OrderedItems([])
    /// Photos linked to a backed-up item as copies of it (`LibraryStore.aliases`), by local identifier.
    private var aliases: [String: String] = [:]
    private var loaded = false

    func entries(applying changes: Changes) -> [GalleryEntry] {
        let env = AppEnvironment.shared
        if changes.everything || !loaded {
            loadAssets()
            // A failed read must not stick: the next refresh reads everything again.
            if let all = try? env.store.allItems() {
                items = OrderedItems(all)
                loaded = true
            } else {
                loaded = false
            }
        } else {
            // Access taken away in Settings: stop showing the photos read while it was allowed.
            if fetch != nil, !PhotoLibraryService.hasAccess { loadAssets() }
            if !changes.itemIds.isEmpty {
                // The changed ids are used up by this refresh; if they can't be read, only a full read can recover them.
                if let fresh = try? env.store.items(ids: changes.itemIds) {
                    items.update(ids: changes.itemIds, fresh: fresh)
                } else {
                    loaded = false
                }
            }
            for change in changes.photoChanges { apply(change) }
        }
        // A small table; read each time, so a copy linked during a backup gets its badge at once.
        aliases = Dictionary(((try? env.store.aliases()) ?? []).map { ($0.localIdentifier, $0.itemId) }, uniquingKeysWith: { a, _ in a })
        // Newest first, like the store, so the item kept for a photo with two items is always the same one.
        return GalleryModel.merge(assets: assets, items: items, aliases: aliases)
    }

    private func loadAssets() {
        guard PhotoLibraryService.hasAccess else { fetch = nil; assets = []; return }
        let result = AppEnvironment.shared.photos.fetchAllAssets()
        var list: [PHAsset] = []
        list.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in list.append(asset) }
        fetch = result
        assets = list
    }

    private func apply(_ change: PHChange) {
        guard let fetch else { return loadAssets() }
        guard let details = change.changeDetails(for: fetch) else { return }
        guard details.hasIncrementalChanges, !details.hasMoves else { return loadAssets() }
        let after = details.fetchResultAfterChanges
        let inserted = zip(details.insertedIndexes ?? [], details.insertedObjects).map { (index: $0, element: $1) }
        let changed = zip(details.changedIndexes ?? [], details.changedObjects).map { (index: $0, element: $1) }
        guard let patched = ArrayChanges.apply(to: assets, removed: details.removedIndexes ?? [], inserted: inserted, changed: changed),
              patched.count == after.count else { return loadAssets() }
        self.fetch = after
        assets = patched
    }
}

extension LibraryStore {
    /// The backed-up items the timeline shows as cloud-only, by the same rule as `GalleryModel.merge`: not hidden, and
    /// with no photo on this device, neither their own nor a copy linked to them (aliases). Search and Similar Photos
    /// must use this too: a backup whose copy is on the phone listed as its own photo could be trashed as a "duplicate".
    func cloudOnlyItems(present: Set<String>) -> [MediaItem] {
        let linked = Set(((try? aliases()) ?? []).filter { present.contains($0.localIdentifier) }.map(\.itemId))
        return ((try? items(status: .backedUp)) ?? []).filter { item in
            item.hidden != true && !linked.contains(item.id) && (item.localIdentifier.map { !present.contains($0) } ?? true)
        }
    }
}
