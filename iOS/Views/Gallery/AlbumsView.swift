import SwiftUI
import Photos
import LelvoCore

/// The Collections tab, laid out like Photos' Collections in iOS 18: Memories (trips included) and Recent Days as rows of covers,
/// then albums, places, media types and utilities. Long sections show their first few with See All or Show More.
/// Everything shown is counted once per library change, off the main thread, never while drawing.
struct AlbumsView: View {
    @EnvironmentObject private var model: GalleryModel
    @EnvironmentObject private var memories: MemoriesModel
    @State private var playing: MemoriesModel.Card?
    @State private var showingAll: MemoriesModel.Card?
    @State private var content = Content()
    @State private var mediaExpanded = false
    /// Each section shows this many first; Show More or See All opens the rest.
    private static let shown = 4

    /// Albums and smart albums from PhotoKit, read once per visit (they change rarely).
    @State private var albums: [(title: String, ids: Set<String>)] = []
    @State private var smartTypes: [(title: String, symbol: String, ids: Set<String>)] = []
    @State private var albumsVersion = 0
    @State private var loadingAlbums = false

    private static let smartAlbums: [(PHAssetCollectionSubtype, String, String)] = [
        (.smartAlbumSelfPortraits, "Selfies", "person.crop.square"),
        (.smartAlbumDepthEffect, "Portrait", "cube"),
        (.smartAlbumPanoramas, "Panoramas", "pano"),
        (.smartAlbumTimelapses, "Time-lapse", "timelapse"),
        (.smartAlbumSlomoVideos, "Slo-mo", "slowmo"),
        (.smartAlbumBursts, "Bursts", "square.stack.3d.down.right"),
        (.smartAlbumScreenshots, "Screenshots", "camera.viewfinder"),
        (.smartAlbumScreenRecordings, "Screen Recordings", "record.circle"),
        (.smartAlbumAnimated, "Animated", "square.stack.3d.forward.dottedline"),
        (.smartAlbumRAW, "RAW", "r.square")
    ]

    /// What the sections show, computed together.
    struct Content {
        struct Row: Identifiable {
            let filter: GalleryFilter
            let symbol: String
            let count: Int
            let cover: GalleryEntry?
            /// Kind and title: an album named "Favorites" or "Screenshots" is not the pinned row of that name.
            var id: String { "\(symbol)|\(filter.title)" }
        }
        var days: [Row] = []
        var albums: [Row] = []
        var media: [Row] = []
        var documents: Row?
        var trashed = 0
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if !memories.cards.isEmpty { memoriesRow }
                    if !content.days.isEmpty { coverRow("Recent Days", rows: content.days) }
                    if !content.albums.isEmpty { albumsSection }
                    groupedSection("Places") {
                        linkRow("Map", symbol: "map") { PhotoMapView { filter in GalleryView(filter: filter, embedInNavigation: false) } }
                    }
                    if !content.media.isEmpty { mediaSection }
                    groupedSection("Utilities") {
                        linkRow("Duplicates and Similar", symbol: "square.on.square") { DuplicatesView() }
                        if let docs = content.documents {
                            Divider().padding(.leading, 52)
                            linkRow(docs.filter.title, symbol: docs.symbol, count: docs.count) { GalleryView(filter: docs.filter, embedInNavigation: false) }
                        }
                        Divider().padding(.leading, 52)
                        linkRow("Recently Deleted", symbol: "trash", count: content.trashed) { RecentlyDeletedView() }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle("Collections")
            .settingsButton()
            .fullScreenCover(item: $playing) { card in
                MemoryStoryView(card: card, entries: card.memory.ids.compactMap { memories.entries[$0] }) {
                    playing = nil
                    showingAll = card
                }
            }
            .navigationDestination(item: $showingAll) { card in
                GalleryView(filter: .matching(title: card.title, ids: Set(card.memory.allIds)), embedInNavigation: false)
            }
            // Read again on every visit, so an album an app just made (WhatsApp, Instagram…) shows at once.
            .onAppear { Task { await loadAlbums() } }
            .task(id: "\(model.revision)-\(albumsVersion)") { await recompute() }
        }
    }

    // MARK: - Sections

    private func sectionHeader<Destination: View>(_ title: String, seeAll: (() -> Destination)? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.bold()).accessibilityAddTraits(.isHeader)
            Spacer()
            if let seeAll { NavigationLink("See All", destination: seeAll) }
        }
    }

    /// Memories as a row of covers, like Google Photos; tap plays, See All lists them.
    private var memoriesRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Memories") { MemoriesView(model: memories) { f in GalleryView(filter: f, embedInNavigation: false) } }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(memories.cards.prefix(Self.shown)) { card in
                        Button { playing = card } label: {
                            MemoryCover(card: card, cover: memories.entries[card.memory.cover]).frame(width: 150, height: 200)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(card.title), \(card.subtitle)")
                    }
                }
            }
        }
    }

    /// Recent Days, like Photos: a cover per day that opens its photos.
    private func coverRow(_ title: String, rows: [Content.Row]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title, seeAll: rows.count > Self.shown ? { AllDaysView(rows: rows) } : nil)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(rows.prefix(Self.shown)) { row in
                        NavigationLink { GalleryView(filter: row.filter, embedInNavigation: false) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                AlbumCover(entry: row.cover, symbol: row.symbol).frame(width: 130)
                                Text(row.filter.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                                Text(row.count.formatted()).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(width: 130)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(row.filter.title), \(row.count) items")
                    }
                }
            }
        }
    }

    /// The first four albums (Favorites and Screenshots first); See All opens every one.
    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Albums", seeAll: content.albums.count > Self.shown ? { AllAlbumsView(albums: content.albums) } : nil)
            AlbumGrid(albums: Array(content.albums.prefix(Self.shown)))
        }
    }

    private var mediaSection: some View {
        let rows = mediaExpanded ? content.media : Array(content.media.prefix(Self.shown))
        return VStack(alignment: .leading, spacing: 12) {
            Text("Media Types").font(.title3.bold()).accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                    linkRow(row.filter.title, symbol: row.symbol, count: row.count) { GalleryView(filter: row.filter, embedInNavigation: false) }
                    if i < rows.count - 1 { Divider().padding(.leading, 52) }
                }
                if content.media.count > Self.shown {
                    Divider().padding(.leading, 52)
                    Button { withAnimation { mediaExpanded.toggle() } } label: {
                        Text(mediaExpanded ? "Show Less" : "Show More").frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func groupedSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold()).accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) { content() }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func linkRow<Destination: View>(_ title: String, symbol: String, count: Int? = nil,
                                            @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.body).foregroundStyle(.tint).frame(width: 24)
                Text(title).foregroundStyle(.primary)
                Spacer()
                if let count { Text(count.formatted()).foregroundStyle(.secondary).monospacedDigit() }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count.map { "\(title), \($0) items" } ?? title)
    }

    // MARK: - Data

    /// Counts, covers and recent days for every section in one pass over the timeline, off the main thread.
    private func recompute() async {
        let entries = model.entries
        let albums = self.albums, smartTypes = self.smartTypes
        let store = AppEnvironment.shared.store
        content = await Task.detached(priority: .userInitiated) { () -> Content in
            var c = Content()
            func row(_ f: GalleryFilter, _ symbol: String) -> Content.Row? {
                let matching = entries.lazy.filter(f.matches)
                let count = matching.count
                return count == 0 ? nil : .init(filter: f, symbol: symbol, count: count, cover: matching.first)
            }
            // Recent Days: the last ten days with photos, newest first.
            let calendar = Calendar.current
            var days: [(Date, [GalleryEntry])] = []
            for e in entries {
                guard let d = e.date else { continue }
                let day = calendar.startOfDay(for: d)
                if let last = days.last, last.0 == day { days[days.count - 1].1.append(e); continue }
                if days.count == 10 { break }
                days.append((day, [e]))
            }
            let dayTitle = DateFormatter()
            dayTitle.setLocalizedDateFormatFromTemplate("EEEdMMM")
            c.days = days.map { day, list in
                let title = calendar.isDateInToday(day) ? "Today" : (calendar.isDateInYesterday(day) ? "Yesterday" : dayTitle.string(from: day))
                return .init(filter: .matching(title: title, ids: Set(list.map(\.id))), symbol: "calendar", count: list.count, cover: list.first)
            }
            // Like Photos: Favorites and Screenshots first, then every album, including the ones apps make (WhatsApp,
            // Instagram, Snapchat…).
            let pinned = ["Screenshots"]
            var albumRows: [Content.Row?] = [row(.favorites, "heart")]
            albumRows += smartTypes.filter { pinned.contains($0.title) }.map { row(.album(title: $0.title, localIds: $0.ids), $0.symbol) }
            albumRows += albums.map { row(.album(title: $0.title, localIds: $0.ids), "photo.on.rectangle") }
            c.albums = albumRows.compactMap { $0 }
            var media: [Content.Row?] = [row(.videos, "video"), row(.livePhotos, "livephoto")]
            media += smartTypes.filter { !pinned.contains($0.title) }.map { row(.album(title: $0.title, localIds: $0.ids), $0.symbol) }
            media += [row(.cloudOnly, "icloud"), row(.notBackedUp, "icloud.slash")]
            c.media = media.compactMap { $0 }
            // Receipts, documents and screenshots Vision recognised while reading photos for search.
            let documents = Set(((try? store.photoFacts()) ?? [:]).filter(\.value.utility).keys)
            c.documents = row(.matching(title: "Documents and Receipts", ids: documents), "doc.text")
            c.trashed = GalleryActions.trashedItems().count
            return c
        }.value
    }

    private func loadAlbums() async {
        guard !loadingAlbums else { return }
        loadingAlbums = true
        defer { loadingAlbums = false }
        let cloudNames = Set(model.entries.compactMap(\.item).flatMap { $0.albums ?? [] })
        let types = Self.smartAlbums
        let (albums, smart) = await Task.detached(priority: .userInitiated) { () -> ([(title: String, ids: Set<String>)], [(title: String, symbol: String, ids: Set<String>)]) in
            var byTitle: [String: Set<String>] = [:]
            var smart: [(title: String, symbol: String, ids: Set<String>)] = []
            if PhotoLibraryService.hasAccess {
                PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil).enumerateObjects { c, _, _ in
                    var ids = Set<String>()
                    PHAsset.fetchAssets(in: c, options: nil).enumerateObjects { a, _, _ in ids.insert(a.localIdentifier) }
                    byTitle[c.localizedTitle ?? "Album", default: []].formUnion(ids)
                }
                for (subtype, title, symbol) in types {
                    var ids = Set<String>()
                    PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil).enumerateObjects { c, _, _ in
                        PHAsset.fetchAssets(in: c, options: nil).enumerateObjects { a, _, _ in ids.insert(a.localIdentifier) }
                    }
                    if !ids.isEmpty { smart.append((title, symbol, ids)) }
                }
            }
            for name in cloudNames where byTitle[name] == nil { byTitle[name] = [] }
            let albums = byTitle.map { (title: $0.key, ids: $0.value) }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            return (albums, smart)
        }.value
        let changed = albums.map(\.title) != self.albums.map(\.title) || albums.map(\.ids.count) != self.albums.map(\.ids.count)
            || smart.map(\.ids.count) != smartTypes.map(\.ids.count)
        self.albums = albums
        smartTypes = smart
        if changed || albumsVersion == 0 { albumsVersion += 1 }
    }
}

/// Album covers two across, like Photos.
private struct AlbumGrid: View {
    let albums: [AlbumsView.Content.Row]
    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            ForEach(albums) { row in
                NavigationLink { GalleryView(filter: row.filter, embedInNavigation: false) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        AlbumCover(entry: row.cover, symbol: row.symbol)
                        Text(row.filter.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1).padding(.top, 4)
                        Text(row.count.formatted()).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(row.filter.title), \(row.count) items")
            }
        }
    }
}

/// Every album (Collections → My Albums → See All).
private struct AllAlbumsView: View {
    let albums: [AlbumsView.Content.Row]

    var body: some View {
        ScrollView {
            AlbumGrid(albums: albums).padding(16)
        }
        .navigationTitle("Albums")
    }
}

/// Every recent day (Collections → Recent Days → See All).
private struct AllDaysView: View {
    let rows: [AlbumsView.Content.Row]

    var body: some View {
        List(rows) { row in
            NavigationLink { GalleryView(filter: row.filter, embedInNavigation: false) } label: {
                LabeledContent(row.filter.title, value: row.count.formatted())
            }
        }
        .navigationTitle("Recent Days")
    }
}

/// Square cover that always fills its tile (never overflows into neighbours), from the grid's thumbnail cache.
private struct AlbumCover: View {
    let entry: GalleryEntry?
    let symbol: String
    @State private var image: UIImage?

    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .task(id: entry?.id) {
                guard let entry else { image = nil; return }
                for await img in ThumbnailPipeline.shared.images(for: entry, pixels: 400) { image = img }
            }
    }
}
