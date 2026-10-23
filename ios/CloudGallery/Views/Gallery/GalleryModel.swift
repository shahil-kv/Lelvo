import Foundation
import Photos
import SwiftUI
import CloudGalleryCore

/// One tile in the unified timeline: a phone asset, a cloud item, or both.
struct GalleryEntry: Identifiable, Equatable, Hashable {
    let id: String
    let date: Date?
    let asset: PHAsset?
    let item: LibraryItem?

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
        case .queued, .uploading: return .uploading
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
    @Published var authorization = PhotoLibraryService.authorizationStatus

    private let env = AppEnvironment.shared
    private var reloadTask: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private var groupByMonth = false

    override init() {
        super.init()
        if PhotoLibraryService.hasAccess { PHPhotoLibrary.shared().register(self) }
        observer = NotificationCenter.default.addObserver(forName: LibraryStore.didChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleReload() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in self.scheduleReload() }
    }

    func setGrouping(byMonth: Bool) {
        guard byMonth != groupByMonth else { return }
        groupByMonth = byMonth
        sections = Self.group(entries, byMonth: byMonth)
    }

    func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await reload()
        }
    }

    func reload() async {
        authorization = PhotoLibraryService.authorizationStatus
        let env = self.env
        let byMonth = groupByMonth
        let (entries, sections) = await Task.detached(priority: .userInitiated) { () -> ([GalleryEntry], [GallerySection]) in
            let assets: PHFetchResult<PHAsset>? = PhotoLibraryService.hasAccess ? env.photos.fetchAllAssets() : nil
            let items = (try? env.store.allItems()) ?? []
            let merged = Self.merge(assets: assets, items: items)
            return (merged, Self.group(merged, byMonth: byMonth))
        }.value
        self.entries = entries
        self.sections = sections
        loaded = true
    }

    nonisolated static func merge(assets: PHFetchResult<PHAsset>?, items: [LibraryItem]) -> [GalleryEntry] {
        var byLocal: [String: LibraryItem] = [:]
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

    nonisolated static func group(_ entries: [GalleryEntry], byMonth: Bool) -> [GallerySection] {
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
            let title: String
            if let date = entry.date {
                let c = cal.dateComponents([.year, .month, .day], from: date)
                key = byMonth ? "\(c.year!)-\(c.month!)" : "\(c.year!)-\(c.month!)-\(c.day!)"
                if key != currentKey {
                    if cal.isDateInToday(date) && !byMonth { title = "Today" }
                    else if cal.isDateInYesterday(date) && !byMonth { title = "Yesterday" }
                    else { title = (byMonth ? monthFormatter : dayFormatter).string(from: date) }
                } else { title = currentTitle }
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
        return sections
    }

    func registerForChangesIfNeeded() {
        if PhotoLibraryService.hasAccess { PHPhotoLibrary.shared().register(self) }
    }
}
