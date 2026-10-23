import SwiftUI
import Photos
import PhotosUI
import CloudGalleryCore

/// What a grid shows: the whole timeline, or a smart/device album.
enum GalleryFilter: Hashable {
    case videos, livePhotos, favorites, cloudOnly
    case album(title: String, localIds: Set<String>)

    var title: String {
        switch self {
        case .videos: return "Videos"
        case .livePhotos: return "Live Photos"
        case .favorites: return "Favorites"
        case .cloudOnly: return "Only in the cloud"
        case .album(let t, _): return t
        }
    }

    func matches(_ e: GalleryEntry) -> Bool {
        switch self {
        case .videos: return e.isVideo
        case .livePhotos: return e.isLive
        case .favorites: return e.asset?.isFavorite == true || e.item?.favorite == true
        case .cloudOnly: return e.isCloudOnly
        case .album(let title, let ids):
            return e.asset.map { ids.contains($0.localIdentifier) } == true || e.item?.albums?.contains(title) == true
        }
    }
}

struct GalleryView: View {
    var filter: GalleryFilter?
    var embedInNavigation = true

    @EnvironmentObject private var model: GalleryModel
    @AppStorage(Prefs.Key.gridColumns) private var columns = 4
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var viewerStart: GalleryEntry?
    @State private var share: ShareItems?
    @State private var busyMessage: String?
    @State private var alert: GalleryAlert?
    @State private var confirmCloudDelete = false
    @State private var confirmDeviceDelete = false
    @State private var pinchScale: CGFloat = 1
    @State private var cellFrames: [String: CGRect] = [:]
    @State private var dragAnchor: Int?
    @State private var dragBase = Set<String>()

    private let spacing: CGFloat = 2

    private var grouping: GalleryModel.Grouping { GalleryModel.Grouping(columns: columns) }
    private var entries: [GalleryEntry] { filter.map { f in model.entries.filter(f.matches) } ?? model.entries }
    private var sections: [GallerySection] {
        filter == nil ? model.sections : GalleryModel.group(entries, grouping: grouping)
    }

    var body: some View {
        if embedInNavigation { NavigationStack { content } } else { content }
    }

    private var content: some View {
        Group {
            if !model.loaded {
                ProgressView("Loading your library…")
            } else if entries.isEmpty {
                if filter != nil {
                    EmptyStateView(systemImage: "photo.on.rectangle", title: "Nothing here yet", message: "Items appear here as you take and back up photos.")
                } else {
                    emptyState
                }
            } else {
                grid
            }
        }
        .navigationTitle(filter?.title ?? "Photos")
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) { if selecting { selectionBar } }
        .overlay {
            if let busyMessage {
                ProgressView(busyMessage)
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .task { if !model.loaded { await model.reload() } }
        .onChange(of: columns) { _, c in model.setGrouping(GalleryModel.Grouping(columns: c)) }
        .onAppear { model.setGrouping(grouping) }
        .fullScreenCover(item: $viewerStart) { start in
            ViewerView(entries: entries, startId: start.id)
        }
        .sheet(item: $share) { ActivityView(items: $0.urls).presentationDetents([.medium, .large]) }
        .alert(item: $alert) { a in Alert(title: Text(a.title), message: Text(a.message)) }
        .confirmationDialog("Delete \(selection.count) item(s) from your Telegram library?", isPresented: $confirmCloudDelete,
                            titleVisibility: .visible) {
            Button("Delete from cloud", role: .destructive) { Task { await deleteFromCloud() } }
        } message: {
            Text("Every message of these items is deleted from the channel. Items still on this iPhone stay there and will be backed up again on the next run.")
        }
        .confirmationDialog("Delete from this iPhone?", isPresented: $confirmDeviceDelete, titleVisibility: .visible) {
            Button("Delete from iPhone", role: .destructive) { Task { await deleteFromDevice() } }
        } message: {
            let notBacked = selectedEntries.filter { $0.asset != nil && $0.badge != .backedUp }.count
            Text(notBacked > 0
                 ? "\(notBacked) of these are NOT backed up yet and would be lost after Recently Deleted is emptied."
                 : "They stay in your Telegram library and in CloudGallery as cloud items.")
        }
    }

    private var selectedEntries: [GalleryEntry] { entries.filter { selection.contains($0.id) } }

    // MARK: - Grid

    private var grid: some View {
        GeometryReader { geo in
            let side = max(20, (geo.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
            ScrollViewReader { proxy in
                ScrollView {
                    if model.authorization == .limited && filter == nil { limitedBanner.padding(.horizontal) }
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: spacing), count: columns),
                              spacing: spacing, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections) { section in
                            Section {
                                ForEach(section.entries) { entry in
                                    ThumbnailCell(entry: entry, side: side, selecting: selecting,
                                                  selected: selection.contains(entry.id))
                                        .background {
                                            if selecting {
                                                GeometryReader { g in
                                                    Color.clear.preference(key: CellFramesKey.self,
                                                                           value: [entry.id: g.frame(in: .named("grid"))])
                                                }
                                            }
                                        }
                                        .onTapGesture { tap(entry) }
                                        .onLongPressGesture {
                                            Haptics.tap()
                                            selecting = true
                                            selection.insert(entry.id)
                                        }
                                }
                            } header: {
                                Text(section.title)
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(.bar)
                                    .id(section.id)
                                    .accessibilityAddTraits(.isHeader)
                            }
                        }
                    }
                    .scaleEffect(pinchScale, anchor: .top)
                }
                .coordinateSpace(name: "grid")
                .onPreferenceChange(CellFramesKey.self) { cellFrames = $0 }
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { v in pinchScale = min(1.15, max(0.85, v.magnification)) }
                        .onEnded { v in
                            withAnimation(.spring(duration: 0.3)) {
                                pinchScale = 1
                                if v.magnification > 1.15 { columns = max(1, columns - 1) }
                                else if v.magnification < 0.85 { columns = min(10, columns + 1) }
                            }
                            Haptics.tap()
                        }
                )
                .simultaneousGesture(selecting ? dragSelect : nil)
                .overlay(alignment: .trailing) {
                    if sections.count > 8 {
                        DateScrubber(sections: sections) { id in proxy.scrollTo(id, anchor: .top) }
                    }
                }
                .refreshable { await model.reload() }
            }
        }
    }

    /// Drag across thumbnails to select a range, like Photos. Starts only on a mostly horizontal drag
    /// so vertical swipes still scroll.
    private var dragSelect: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .named("grid"))
            .onChanged { v in
                let flat = entries.map(\.id)
                guard let hit = cellFrames.first(where: { $0.value.contains(v.location) })?.key,
                      let index = flat.firstIndex(of: hit) else { return }
                if dragAnchor == nil {
                    guard abs(v.translation.width) > abs(v.translation.height) else { return }
                    guard let start = cellFrames.first(where: { $0.value.contains(v.startLocation) })?.key,
                          let s = flat.firstIndex(of: start) else { return }
                    dragAnchor = s
                    dragBase = selection
                    Haptics.tap()
                }
                guard let anchor = dragAnchor else { return }
                let range = min(anchor, index)...max(anchor, index)
                selection = dragBase.union(flat[range])
            }
            .onEnded { _ in dragAnchor = nil }
    }

    private var limitedBanner: some View {
        HStack {
            Label("CloudGallery can only see the photos you selected.", systemImage: "photo.badge.exclamationmark")
                .font(.footnote)
            Spacer()
            Button("Manage") { presentLimitedPicker() }.font(.footnote.bold())
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var emptyState: some View {
        switch model.authorization {
        case .denied, .restricted:
            EmptyStateView(systemImage: "photo.badge.exclamationmark", title: "No photo access",
                           message: "Allow access in Settings to back up and browse your photos. Cloud items appear here after a backup or restore.",
                           actionTitle: "Open Settings") {
                UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
            }
        case .notDetermined:
            EmptyStateView(systemImage: "photo.on.rectangle", title: "Allow photo access",
                           message: "CloudGallery needs access to back up your library.", actionTitle: "Allow") {
                Task {
                    _ = await PhotoLibraryService.requestAuthorization()
                    model.registerForChangesIfNeeded()
                    await model.reload()
                }
            }
        default:
            EmptyStateView(systemImage: "photo.on.rectangle", title: "No photos yet",
                           message: "Photos and videos on this iPhone, and everything in your Telegram backup, show up here.")
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(selecting ? "Done" : "Select") {
                selecting.toggle()
                selection.removeAll()
            }
            .disabled(entries.isEmpty)
        }
        if !selecting {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Picker("Columns", selection: $columns) {
                        ForEach([2, 3, 4, 5, 6, 8, 10], id: \.self) { Text("\($0) columns").tag($0) }
                    }
                } label: { Image(systemName: "square.grid.3x3") }
                .accessibilityLabel("Grid size")
            }
        }
    }

    private var selectionBar: some View {
        let chosen = selectedEntries
        let cloudItems = chosen.compactMap(\.item).filter { $0.status == .backedUp }
        let downloadable = chosen.filter { $0.isCloudOnly && $0.item?.isViewableFromCloud == true }
        let onDevice = chosen.filter { $0.asset != nil }
        return HStack {
            Button { Task { await shareSelection(chosen) } } label: { Label("Share", systemImage: "square.and.arrow.up") }
                .disabled(chosen.isEmpty)
            Spacer()
            Button { Task { await download(downloadable) } } label: { Label("Save", systemImage: "square.and.arrow.down") }
                .disabled(downloadable.isEmpty)
            Spacer()
            Text("\(selection.count) selected").font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Button { confirmDeviceDelete = true } label: { Label("Delete from iPhone", systemImage: "iphone.slash") }
                .disabled(onDevice.isEmpty)
            Spacer()
            Button(role: .destructive) { confirmCloudDelete = true } label: { Label("Delete from cloud", systemImage: "trash") }
                .disabled(cloudItems.isEmpty)
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .padding()
        .background(.bar)
    }

    // MARK: - Actions

    private func tap(_ entry: GalleryEntry) {
        if selecting {
            if selection.contains(entry.id) { selection.remove(entry.id) } else { selection.insert(entry.id) }
            Haptics.tap()
        } else {
            viewerStart = entry
        }
    }

    private func presentLimitedPicker() {
        guard let root = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top)
    }

    private func shareSelection(_ entries: [GalleryEntry]) async {
        busyMessage = "Preparing \(entries.count) item(s)…"
        defer { busyMessage = nil }
        var urls: [URL] = []
        var skipped = 0
        for entry in entries {
            do { urls.append(try await GalleryActions.shareableFile(for: entry)) } catch { skipped += 1 }
        }
        if !urls.isEmpty { share = ShareItems(urls: urls) }
        if skipped > 0 {
            alert = GalleryAlert(title: "Some items weren't shared",
                                 message: "\(skipped) item(s) couldn't be downloaded. Check your connection and try again.")
        }
    }

    private func download(_ entries: [GalleryEntry]) async {
        busyMessage = "Saving to Photos…"
        defer { busyMessage = nil }
        var saved = 0
        var failures: [String] = []
        for entry in entries {
            guard let item = entry.item else { continue }
            do {
                try await GalleryActions.saveToPhotos(item)
                saved += 1
            } catch { failures.append(error.localizedDescription) }
        }
        selecting = false
        selection.removeAll()
        if failures.isEmpty {
            Haptics.success()
            alert = GalleryAlert(title: "Saved", message: "\(saved) item(s) saved to your photo library.")
        } else {
            Haptics.error()
            alert = GalleryAlert(title: "Saved \(saved), \(failures.count) failed", message: failures.first ?? "")
        }
    }

    private func deleteFromDevice() async {
        let ids = selectedEntries.compactMap { $0.asset?.localIdentifier }
        do {
            try await AppEnvironment.shared.photos.deleteAssets(ids)
            Haptics.success()
            selecting = false
            selection.removeAll()
            alert = GalleryAlert(title: "Moved to Recently Deleted",
                                 message: "Empty Photos → Albums → Recently Deleted to free the space.")
        } catch {
            // The user cancelled iOS's confirmation, or deletion failed.
        }
    }

    private func deleteFromCloud() async {
        let items = selectedEntries.compactMap(\.item).filter { $0.status == .backedUp }
        busyMessage = "Deleting from cloud…"
        defer { busyMessage = nil }
        do {
            try await GalleryActions.deleteFromCloud(items)
            Haptics.success()
            selecting = false
            selection.removeAll()
        } catch {
            Haptics.error()
            alert = GalleryAlert(title: "Couldn't delete", message: error.localizedDescription)
        }
    }
}

struct GalleryAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct ThumbnailCell: View {
    let entry: GalleryEntry
    let side: CGFloat
    let selecting: Bool
    let selected: Bool
    @State private var image: UIImage?
    @State private var failed = false
    @Environment(\.displayScale) private var scale

    var body: some View {
        ZStack {
            Rectangle().fill(Color(.secondarySystemBackground))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: side, height: side).clipped()
            } else if failed {
                Image(systemName: entry.badge == .tooLarge ? "doc.badge.ellipsis" : "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: side, height: side)
        .overlay(alignment: .bottomLeading) {
            if entry.isVideo, let d = entry.duration {
                Text(Duration.seconds(d).formatted(.time(pattern: .minuteSecond)))
                    .font(.caption2.monospacedDigit().bold()).foregroundStyle(.white)
                    .shadow(radius: 2).padding(4)
            } else if entry.isLive {
                Image(systemName: "livephoto").font(.caption2).foregroundStyle(.white).shadow(radius: 2).padding(4)
            }
        }
        .overlay(alignment: .topTrailing) {
            if entry.badge != .backedUp || side > 70 { BadgeView(badge: entry.badge).padding(4) }
        }
        .overlay(alignment: .bottomTrailing) {
            if selecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(selected ? Color.accentColor : .white)
                    .background(Circle().fill(selected ? .white : .black.opacity(0.2)))
                    .padding(5)
            }
        }
        .overlay { if selected { Rectangle().stroke(Color.accentColor, lineWidth: 3) } }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.accessibilityLabel)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .task(id: entry.id) { await load() }
    }

    private func load() async {
        let env = AppEnvironment.shared
        if let asset = entry.asset {
            let px = side * scale
            image = await env.photos.image(for: asset, targetSize: CGSize(width: px, height: px))
        } else if let item = entry.item {
            if let cached = env.media.cachedThumbnail(for: item) { image = cached; return }
            do { image = try await env.media.thumbnail(for: item) } catch { failed = true }
        }
        if image == nil { failed = true }
    }
}

struct CellFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Fast date scrubber on the trailing edge: drag to jump through months/years.
struct DateScrubber: View {
    let sections: [GallerySection]
    let jump: (String) -> Void
    @State private var dragging = false
    @State private var label = ""
    @State private var lastId = ""

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .trailing) {
                Capsule()
                    .fill(.secondary.opacity(dragging ? 0.5 : 0.25))
                    .frame(width: dragging ? 6 : 4)
                    .padding(.vertical, 8)
                if dragging {
                    Text(label)
                        .font(.caption.bold())
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .offset(x: -18)
                        .transition(.opacity)
                }
            }
            .frame(width: 44)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        dragging = true
                        let fraction = min(max(v.location.y / max(geo.size.height, 1), 0), 0.9999)
                        let s = sections[Int(fraction * Double(sections.count))]
                        label = s.title
                        if s.id != lastId {
                            lastId = s.id
                            jump(s.id)
                            UISelectionFeedbackGenerator().selectionChanged()
                        }
                    }
                    .onEnded { _ in withAnimation { dragging = false } }
            )
            .accessibilityLabel("Date scrubber")
            .accessibilityHint("Drag to jump to a date")
        }
        .frame(width: 44)
    }
}
