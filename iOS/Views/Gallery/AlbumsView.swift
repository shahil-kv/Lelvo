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
                        if ProStore.offered {
                            linkRow("Locked Folder", symbol: "lock.fill", pro: true) {
                                LockedFolderView()
                            }
                            Divider().padding(.leading, 52)
                            linkRow("Smart Cleanup", symbol: "wand.and.stars", pro: true) { DuplicatesView() }
                        }
                        if let docs = content.documents {
                            if ProStore.offered { Divider().padding(.leading, 52) }
                            linkRow(docs.filter.title, symbol: docs.symbol, count: docs.count) { GalleryView(filter: docs.filter, embedInNavigation: false) }
                        }
                        if ProStore.offered || content.documents != nil { Divider().padding(.leading, 52) }
                        linkRow("Recently Deleted", symbol: "trash", count: content.trashed) { RecentlyDeletedView() }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle("Collections")
            .settingsButton()
            .fullScreenCover(item: $playing) { card in
                MemoryStoryView(
                    cards: memories.cards,
                    start: memories.cards.firstIndex(of: card) ?? 0,
                    entriesFor: { c in c.memory.ids.compactMap { memories.entries[$0] } },
                    onClose: { playing = nil },
                    showAll: { current in
                        playing = nil
                        showingAll = current
                    }
                )
            }
            .navigationDestination(item: $showingAll) { card in
                GalleryView(filter: .matching(title: card.title, ids: Set(card.memory.allIds)), embedInNavigation: false)
            }
            // Read again on every visit, so an album an app just made (WhatsApp, Instagram…) shows at once.
            .onAppear { Task { await loadAlbums() } }
            .onReceive(NotificationCenter.default.publisher(for: .albumsChanged)) { _ in Task { await loadAlbums() } }
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
                        .accessibilityLabel("\(row.filter.title), \(row.count) \(row.count == 1 ? "item" : "items")")
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

    private func linkRow<Destination: View>(_ title: String, symbol: String, count: Int? = nil, pro: Bool = false,
                                            @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.body).foregroundStyle(.tint).frame(width: 24)
                Text(title).foregroundStyle(.primary)
                if pro { ProBadge() }
                Spacer()
                if let count { Text(count.formatted()).foregroundStyle(.secondary).monospacedDigit() }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count.map { "\(title)\(pro ? ", Pro" : ""), \($0) \($0 == 1 ? "item" : "items")" } ?? "\(title)\(pro ? ", Pro" : "")")
    }

    // MARK: - Data

    /// Counts, covers and recent days for every section in one pass over the timeline, off the main thread.
    private func recompute() async {
        let entries = model.entries
        let albums = self.albums, smartTypes = self.smartTypes
        let store = AppEnvironment.shared.store
        content = await Task.detached(priority: .userInitiated) { () -> Content in
            var c = Content()
            // Every album, as Photos shows them: also empty ones (just made) and ones that so far hold only items in the
            // Telegram library. Normalized via `MetaLog.albumName` so trailing spaces don't create duplicate rows.
            var all = albums
            let known = Set(all.map { MetaLog.albumName($0.title) ?? $0.title })
            let cloudNames = Set(entries.compactMap(\.item).flatMap { $0.albums ?? [] }.compactMap { MetaLog.albumName($0) }).subtracting(known)
            all += cloudNames.map { (title: $0, ids: Set<String>()) }
            all.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

            // Reverse indexes so every album, smart album and media type is counted in one O(N) pass over `entries`.
            var assetToAlbums: [String: [Int]] = [:]
            var titleToAlbum: [String: Int] = [:]
            for (i, album) in all.enumerated() {
                titleToAlbum[MetaLog.albumName(album.title) ?? album.title] = i
                for id in album.ids { assetToAlbums[id, default: []].append(i) }
            }
            var assetToSmart: [String: [Int]] = [:]
            var titleToSmart: [String: Int] = [:]
            for (i, s) in smartTypes.enumerated() {
                titleToSmart[s.title] = i
                for id in s.ids { assetToSmart[id, default: []].append(i) }
            }
            let documents = Set(((try? store.photoFacts()) ?? [:]).filter(\.value.utility).keys)

            var albumCounts = Array(repeating: 0, count: all.count)
            var albumCovers = Array<GalleryEntry?>(repeating: nil, count: all.count)
            var smartCounts = Array(repeating: 0, count: smartTypes.count)
            var smartCovers = Array<GalleryEntry?>(repeating: nil, count: smartTypes.count)
            var favCount = 0, videoCount = 0, liveCount = 0, cloudCount = 0, notBackedCount = 0, docCount = 0
            var favCover: GalleryEntry?, videoCover: GalleryEntry?, liveCover: GalleryEntry?, cloudCover: GalleryEntry?, notBackedCover: GalleryEntry?, docCover: GalleryEntry?

            let calendar = Calendar.current
            var days: [(Date, [GalleryEntry])] = []
            var daysDone = false

            for e in entries {
                if !daysDone, let d = e.date {
                    let day = calendar.startOfDay(for: d)
                    if let last = days.last, last.0 == day {
                        days[days.count - 1].1.append(e)
                    } else if days.count < 10 {
                        days.append((day, [e]))
                    } else {
                        daysDone = true
                    }
                }
                if e.asset?.isFavorite == true || e.item?.favorite == true {
                    favCount += 1; if favCover == nil { favCover = e }
                }
                if e.isVideo {
                    videoCount += 1; if videoCover == nil { videoCover = e }
                }
                if e.isLive {
                    liveCount += 1; if liveCover == nil { liveCover = e }
                }
                if e.isCloudOnly {
                    cloudCount += 1; if cloudCover == nil { cloudCover = e }
                }
                if [.phoneOnly, .waiting, .failed].contains(e.badge) {
                    notBackedCount += 1; if notBackedCover == nil { notBackedCover = e }
                }
                if documents.contains(e.id) {
                    docCount += 1; if docCover == nil { docCover = e }
                }
                var matchedAlbums = Set<Int>()
                if let localId = e.asset?.localIdentifier, let idxs = assetToAlbums[localId] {
                    matchedAlbums.formUnion(idxs)
                }
                if let itemAlbums = e.item?.albums {
                    for name in itemAlbums {
                        if let idx = titleToAlbum[MetaLog.albumName(name) ?? name] { matchedAlbums.insert(idx) }
                    }
                }
                for idx in matchedAlbums {
                    albumCounts[idx] += 1; if albumCovers[idx] == nil { albumCovers[idx] = e }
                }
                var matchedSmart = Set<Int>()
                if let localId = e.asset?.localIdentifier, let idxs = assetToSmart[localId] {
                    matchedSmart.formUnion(idxs)
                }
                if let itemAlbums = e.item?.albums {
                    for name in itemAlbums {
                        if let idx = titleToSmart[name] { matchedSmart.insert(idx) }
                    }
                }
                for idx in matchedSmart {
                    smartCounts[idx] += 1; if smartCovers[idx] == nil { smartCovers[idx] = e }
                }
            }

            let dayTitle = DateFormatter()
            dayTitle.setLocalizedDateFormatFromTemplate("EEEdMMM")
            c.days = days.map { day, list in
                let title = calendar.isDateInToday(day) ? "Today" : (calendar.isDateInYesterday(day) ? "Yesterday" : dayTitle.string(from: day))
                return .init(filter: .matching(title: title, ids: Set(list.map(\.id))), symbol: "calendar", count: list.count, cover: list.first)
            }
            func makeRow(_ f: GalleryFilter, _ symbol: String, count: Int, cover: GalleryEntry?) -> Content.Row? {
                count == 0 ? nil : .init(filter: f, symbol: symbol, count: count, cover: cover)
            }
            // Like Photos: Favorites and Screenshots first, then every album, including the ones apps make (WhatsApp,
            // Instagram, Snapchat…).
            let pinned = ["Screenshots"]
            var albumRows: [Content.Row?] = [makeRow(.favorites, "heart", count: favCount, cover: favCover)]
            for (i, s) in smartTypes.enumerated() where pinned.contains(s.title) {
                albumRows.append(makeRow(.album(title: s.title, localIds: s.ids), s.symbol, count: smartCounts[i], cover: smartCovers[i]))
            }
            for (i, album) in all.enumerated() {
                let filter = GalleryFilter.album(title: album.title, localIds: album.ids)
                albumRows.append(.init(filter: filter, symbol: "photo.on.rectangle", count: albumCounts[i], cover: albumCovers[i]))
            }
            c.albums = albumRows.compactMap { $0 }
            var media: [Content.Row?] = [
                makeRow(.videos, "video", count: videoCount, cover: videoCover),
                makeRow(.livePhotos, "livephoto", count: liveCount, cover: liveCover)
            ]
            for (i, s) in smartTypes.enumerated() where !pinned.contains(s.title) {
                media.append(makeRow(.album(title: s.title, localIds: s.ids), s.symbol, count: smartCounts[i], cover: smartCovers[i]))
            }
            media += [
                makeRow(.cloudOnly, "icloud", count: cloudCount, cover: cloudCover),
                makeRow(.notBackedUp, "icloud.slash", count: notBackedCount, cover: notBackedCover)
            ]
            c.media = media.compactMap { $0 }
            c.documents = makeRow(.matching(title: "Documents and Receipts", ids: documents), "doc.text", count: docCount, cover: docCover)
            c.trashed = GalleryActions.trashedItems().count
            return c
        }.value
    }

    private func loadAlbums() async {
        guard !loadingAlbums else { return }
        loadingAlbums = true
        defer { loadingAlbums = false }
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
            let albums = byTitle.map { (title: $0.key, ids: $0.value) }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            return (albums, smart)
        }.value
        let changed = albums.map(\.title) != self.albums.map(\.title) || albums.map(\.ids) != self.albums.map(\.ids)
            || smart.map(\.title) != smartTypes.map(\.title) || smart.map(\.ids) != smartTypes.map(\.ids)
        self.albums = albums
        smartTypes = smart
        if changed || albumsVersion == 0 { albumsVersion += 1 }
    }
}

/// Album covers two across, like Photos.
private struct AlbumGrid: View {
    let albums: [AlbumsView.Content.Row]
    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
    @State private var deleting: String?
    /// Hidden at once after a delete, before the album list is read again.
    @State private var deleted = Set<String>()
    @State private var failure: String?

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            ForEach(albums.filter { !deleted.contains($0.id) }) { row in
                NavigationLink { GalleryView(filter: row.filter, embedInNavigation: false) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        AlbumCover(entry: row.cover, symbol: row.symbol)
                        Text(row.filter.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1).padding(.top, 4)
                        Text(row.count.formatted()).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(row.filter.title), \(row.count) \(row.count == 1 ? "item" : "items")")
                .contextMenu {
                    // Only albums people make: not Favorites or the ones Photos keeps (Screenshots).
                    if row.symbol == Self.userAlbumSymbol {
                        Button(role: .destructive) { deleting = row.filter.title } label: { Label("Delete Album", systemImage: "trash") }
                    }
                }
            }
        }
        .alert("Delete “\(deleting ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Album", role: .destructive) {
                guard let title = deleting else { return }
                Task { await delete(title) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The album is removed from Photos on this iPhone and from Lelvo on your other devices. The photos stay in your library and your Telegram library.")
        }
        // A list read again after a delete no longer has the album; one made again with that name must show.
        .onChange(of: albums.map(\.id)) { _, _ in deleted.removeAll() }
        .alert("Couldn't delete the album", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    static let userAlbumSymbol = "photo.on.rectangle"

    private func delete(_ title: String) async {
        do {
            try await Task.detached { try await GalleryActions.deleteAlbum(title) }.value
            Haptics.success()
            deleted.insert("\(Self.userAlbumSymbol)|\(title)")
        } catch let error as NSError where error.domain == PHPhotosErrorDomain && error.code == PHPhotosError.userCancelled.rawValue {
            // Cancelled in iOS's own confirmation: nothing changed.
        } catch PhotoLibraryError.albumNotDeletable {
            Haptics.error()
            failure = PhotoLibraryError.albumNotDeletable.localizedDescription
        } catch {
            Haptics.error()
            failure = "Photos didn't allow it. Check that Lelvo has full access to your photos, then try again."
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
            // clipShape only clips the drawing: a tall screenshot filling the square still took taps above it, so
            // "See All" opened Screenshots. Taps stay inside the square.
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .task(id: entry?.id) {
                guard let entry else { image = nil; return }
                for await img in ThumbnailPipeline.shared.images(for: entry, pixels: 400) { image = img }
            }
    }
}
