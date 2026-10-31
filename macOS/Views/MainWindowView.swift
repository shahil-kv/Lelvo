import SwiftUI
import Photos
import LelvoCore

/// Everything the sidebar can show, in Apple Photos' order.
enum SidebarItem: Hashable {
    case library, favorites, videos, livePhotos
    case notBackedUp, cloudOnly
    case smart(String)
    case album(String)
    case backup, recentlyDeleted
    case search, map, memories

    var title: String {
        switch self {
        case .library: return "Library"
        case .favorites: return "Favorites"
        case .videos: return "Videos"
        case .livePhotos: return "Live Photos"
        case .notBackedUp: return "Not Backed Up"
        case .cloudOnly: return "Only in Cloud"
        case .smart(let t), .album(let t): return t
        case .backup: return "Backup"
        case .recentlyDeleted: return "Recently Deleted"
        case .search: return "Search"
        case .map: return "Map"
        case .memories: return "Memories"
        }
    }

    var symbol: String {
        switch self {
        case .library: return "photo.on.rectangle"
        case .favorites: return "heart"
        case .videos: return "video"
        case .livePhotos: return "livephoto"
        case .notBackedUp: return "icloud.slash"
        case .cloudOnly: return "icloud"
        case .smart(let t): return MacLibraryIndex.smartAlbums.first { $0.title == t }?.symbol ?? "square.grid.2x2"
        case .album: return "rectangle.stack"
        case .backup: return "arrow.triangle.2.circlepath.icloud"
        case .recentlyDeleted: return "trash"
        case .search: return "magnifyingglass"
        case .map: return "map"
        case .memories: return "sparkles"
        }
    }

    var tint: Color {
        switch self {
        case .favorites: return .pink
        case .notBackedUp: return .orange
        case .cloudOnly: return .cyan
        case .backup: return .green
        default: return .accentColor
        }
    }

    static let goMenu: [SidebarItem] = [.library, .favorites, .videos, .notBackedUp, .backup]

    var shortcut: KeyEquivalent {
        switch self {
        case .library: return "1"
        case .favorites: return "2"
        case .videos: return "3"
        case .notBackedUp: return "4"
        default: return "5"
        }
    }
}

/// Albums, Media Types and per-row counts for the sidebar, recomputed off the main thread when the library changes.
@MainActor
final class MacLibraryIndex: ObservableObject {
    struct Album: Identifiable, Hashable {
        let title: String
        let ids: Set<String>
        var id: String { title }
    }

    nonisolated static let smartAlbums: [(subtype: PHAssetCollectionSubtype, title: String, symbol: String)] = [
        (.smartAlbumSelfPortraits, "Selfies", "person.crop.square"),
        (.smartAlbumDepthEffect, "Portrait", "cube"),
        (.smartAlbumPanoramas, "Panoramas", "pano"),
        (.smartAlbumTimelapses, "Time-lapse", "timelapse"),
        (.smartAlbumSlomoVideos, "Slo-mo", "slowmo"),
        (.smartAlbumScreenshots, "Screenshots", "camera.viewfinder"),
        (.smartAlbumScreenRecordings, "Screen Recordings", "record.circle"),
        (.smartAlbumRAW, "RAW", "r.square")
    ]

    @Published private(set) var albums: [Album] = []
    @Published private(set) var smartTypes: [Album] = []
    @Published private(set) var counts: [SidebarItem: Int] = [:]
    private var loadedRevision = -1

    func filter(for item: SidebarItem) -> GalleryFilter? {
        switch item {
        case .library, .backup, .recentlyDeleted, .search, .map, .memories: return nil
        case .favorites: return .favorites
        case .videos: return .videos
        case .livePhotos: return .livePhotos
        case .notBackedUp: return .notBackedUp
        case .cloudOnly: return .cloudOnly
        case .smart(let t): return .album(title: t, localIds: smartTypes.first { $0.title == t }?.ids ?? [])
        case .album(let t): return .album(title: t, localIds: albums.first { $0.title == t }?.ids ?? [])
        }
    }

    func refresh(entries: [GalleryEntry], revision: Int) async {
        guard revision != loadedRevision else { return }
        loadedRevision = revision
        let cloudNames = Set(entries.compactMap(\.item).flatMap { $0.albums ?? [] })
        let smart = Self.smartAlbums
        let (albums, smartTypes) = await Task.detached(priority: .utility) { () -> ([Album], [Album]) in
            var byTitle: [String: Set<String>] = [:]
            var types: [Album] = []
            if PhotoLibraryService.hasAccess {
                PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil).enumerateObjects { c, _, _ in
                    var ids = Set<String>()
                    PHAsset.fetchAssets(in: c, options: nil).enumerateObjects { a, _, _ in ids.insert(a.localIdentifier) }
                    byTitle[c.localizedTitle ?? "Album", default: []].formUnion(ids)
                }
                for (subtype, title, _) in smart {
                    var ids = Set<String>()
                    PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil).enumerateObjects { c, _, _ in
                        PHAsset.fetchAssets(in: c, options: nil).enumerateObjects { a, _, _ in ids.insert(a.localIdentifier) }
                    }
                    if !ids.isEmpty { types.append(Album(title: title, ids: ids)) }
                }
            }
            for name in cloudNames where byTitle[name] == nil { byTitle[name] = [] }
            let albums = byTitle.map { Album(title: $0.key, ids: $0.value) }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            return (albums, types)
        }.value

        let rows: [SidebarItem] = [.library, .favorites, .videos, .livePhotos, .notBackedUp, .cloudOnly]
            + smartTypes.map { .smart($0.title) } + albums.map { .album($0.title) }
        let filters = rows.map { item -> (SidebarItem, GalleryFilter?) in
            switch item {
            case .smart(let t): return (item, .album(title: t, localIds: smartTypes.first { $0.title == t }?.ids ?? []))
            case .album(let t): return (item, .album(title: t, localIds: albums.first { $0.title == t }?.ids ?? []))
            default: return (item, filter(for: item))
            }
        }
        let counts = await Task.detached(priority: .utility) { () -> [SidebarItem: Int] in
            var out: [SidebarItem: Int] = [:]
            for (item, f) in filters { out[item] = f.map { f in entries.lazy.filter(f.matches).count } ?? entries.count }
            return out
        }.value
        self.albums = albums.filter { (counts[.album($0.title)] ?? 0) > 0 }
        self.smartTypes = smartTypes
        self.counts = counts
    }
}

struct MainWindowView: View {
    @EnvironmentObject private var navigation: MacNavigation
    @StateObject private var gallery = GalleryModel()
    @StateObject private var index = MacLibraryIndex()
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @StateObject private var memories = MemoriesModel()

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            MacSidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 236, max: 320)
        } detail: {
            detail
        }
        .environmentObject(gallery)
        .environmentObject(index)
        .frame(minWidth: 900, minHeight: 600)
        .task { if !gallery.loaded { await gallery.reload() } }
        .task(id: gallery.revision) { await index.refresh(entries: gallery.entries, revision: gallery.revision) }
    }

    @ViewBuilder private var detail: some View {
        switch navigation.selection ?? .library {
        case .backup:
            NavigationStack { MacBackupView() }
        case .recentlyDeleted:
            NavigationStack { RecentlyDeletedView() }
        case .search:
            MacSearchView()
        case .map:
            NavigationStack { PhotoMapView { filter in MacGalleryView(item: .map, filter: filter) } }
        case .memories:
            NavigationStack { MemoriesView(model: memories) { filter in MacGalleryView(item: .memories, filter: filter) } }
        case let item:
            MacGalleryView(item: item, filter: index.filter(for: item))
                .id(item)
        }
    }
}

// MARK: - Sidebar

struct MacSidebar: View {
    @EnvironmentObject private var navigation: MacNavigation
    @EnvironmentObject private var index: MacLibraryIndex
    @EnvironmentObject private var activity: BackupActivity
    @State private var albumsExpanded = true
    @State private var typesExpanded = true

    var body: some View {
        List(selection: $navigation.selection) {
            Section("Photos") {
                row(.library)
                row(.memories)
                row(.search)
                row(.map)
                row(.favorites)
                row(.videos)
                row(.livePhotos)
            }
            Section("Telegram Backup") {
                row(.notBackedUp)
                row(.cloudOnly)
                row(.backup)
                row(.recentlyDeleted)
            }
            if !index.smartTypes.isEmpty {
                Section("Media Types", isExpanded: $typesExpanded) {
                    ForEach(index.smartTypes) { row(.smart($0.title)) }
                }
            }
            if !index.albums.isEmpty {
                Section("Albums", isExpanded: $albumsExpanded) {
                    ForEach(index.albums) { row(.album($0.title)) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarBackupCard()
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
    }

    private func row(_ item: SidebarItem) -> some View {
        Label {
            Text(item.title).lineLimit(1)
        } icon: {
            Image(systemName: item.symbol).foregroundStyle(item.tint)
        }
        .badge(badge(for: item))
        .tag(item)
    }

    private func badge(for item: SidebarItem) -> Int {
        switch item {
        case .backup: return activity.isRunning ? activity.remaining : 0
        case .notBackedUp, .cloudOnly, .favorites: return index.counts[item] ?? 0
        default: return 0
        }
    }
}

/// Always-visible backup status at the bottom of the sidebar, like Google Drive's and Photos' sync footer.
struct SidebarBackupCard: View {
    @EnvironmentObject private var activity: BackupActivity
    @EnvironmentObject private var navigation: MacNavigation
    @EnvironmentObject private var index: MacLibraryIndex
    @AppStorage(Prefs.Key.backupPaused) private var paused = false
    @State private var hovering = false

    private var notBackedUp: Int { index.counts[.notBackedUp] ?? 0 }

    var body: some View {
        Button { navigation.selection = .backup } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 3)
                    if activity.isRunning {
                        Circle()
                            .trim(from: 0, to: activity.total > 0 ? CGFloat(activity.done) / CGFloat(activity.total) : 0.05)
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.easeInOut, value: activity.done)
                    }
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                        .symbolEffect(.pulse, isActive: activity.isRunning)
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(.background.secondary.opacity(hovering ? 1 : 0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help("Open Backup")
    }

    private var icon: String {
        if activity.isRunning { return "arrow.up" }
        if paused && notBackedUp > 0 { return "pause.fill" }
        return notBackedUp > 0 ? "icloud.slash" : "checkmark"
    }

    private var tint: Color {
        if activity.isRunning { return .accentColor }
        return notBackedUp > 0 ? .orange : .green
    }

    private var title: String {
        if activity.isRunning { return "Backing up" }
        if paused && notBackedUp > 0 { return "Backup paused" }
        return notBackedUp > 0 ? "\(notBackedUp.formatted()) not backed up" : "Backup complete"
    }

    private var subtitle: String {
        if activity.isRunning {
            if let notice = activity.notice { return notice }
            return activity.total > 0 ? "\(activity.remaining.formatted()) left" : "Preparing…"
        }
        if let last = UserDefaults.standard.object(forKey: Prefs.Key.lastBackupAt) as? Date {
            return "Last upload \(Format.relative(last))"
        }
        return "To your Telegram library"
    }
}
