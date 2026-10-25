import SwiftUI
import Photos
import PhotosUI
import MemvoCore

struct GalleryView: View {
    var filter: GalleryFilter?
    var embedInNavigation = true

    @EnvironmentObject private var model: GalleryModel
    @AppStorage(Prefs.Key.gridColumns) private var columns = 4
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var share: ShareItems?
    @State private var busyMessage: String?
    @State private var alert: GalleryAlert?
    @State private var confirmCloudDelete = false
    @State private var confirmDeviceDelete = false
    @State private var showLegend = false
    /// The item showing in the viewer (changes as the user swipes).
    @State private var viewerCurrentId: String?
    /// Per-frame scroll values live here, read only by the date scrubber, so nothing else redraws while scrolling.
    @State private var motion = GridMotion()
    @State private var scrubTarget: String?
    @State private var scrubToken = 0
    /// Bumped when the filtered timeline is recomputed, so the grid knows its data changed.
    @State private var filteredVersion = 0

    private var grouping: GalleryModel.Grouping { GalleryModel.Grouping(columns: columns) }
    /// The timeline is already grouped by the model; filtered views (albums, Videos…) are computed once per
    /// library change off the main thread instead of on every render.
    private var entries: [GalleryEntry] { filter == nil ? model.entries : filtered.entries }
    private var sections: [GallerySection] { filter == nil ? model.sections : filtered.sections }
    @State private var filtered: (entries: [GalleryEntry], sections: [GallerySection]) = ([], [])

    private struct FilterKey: Equatable { let revision: Int; let grouping: GalleryModel.Grouping; let size: Int }

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
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(isPresented: $showLegend) { BadgeLegendView() }
        .safeAreaInset(edge: .bottom) { if selecting { selectionBar } }
        .overlay {
            if let busyMessage {
                ProgressView(busyMessage)
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .task { if !model.loaded { await model.reload() } }
        .task(id: FilterKey(revision: model.revision, grouping: grouping, size: filterSize)) {
            let source = model.entries
            let filter = self.filter
            let grouping = self.grouping
            let result = await Task.detached(priority: .userInitiated) { () -> ([GalleryEntry], [GallerySection], [String: Int]) in
                let list = filter.map { f in source.filter(f.matches) } ?? source
                var positions: [String: Int] = [:]
                positions.reserveCapacity(list.count)
                for (i, e) in list.enumerated() { positions[e.id] = i }
                return (list, filter == nil ? [] : GalleryModel.group(list, grouping: grouping), positions)
            }.value
            if filter != nil {
                filtered = (result.0, result.1)
                filteredVersion += 1
            }
        }
        .onChange(of: columns) { _, c in model.setGrouping(GalleryModel.Grouping(columns: c)) }
        .onAppear { model.setGrouping(grouping) }
        .sheet(item: $share) { ActivityView(items: $0.urls).presentationDetents([.medium, .large]) }
        .alert(item: $alert) { a in Alert(title: Text(a.title), message: Text(a.message)) }
        .alert("Delete \(selection.count) from your backup?", isPresented: $confirmCloudDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete from Backup", role: .destructive) { Task { await deleteFromCloud() } }
        } message: {
            Text("They move to Recently Deleted in Memvo and are removed from your Telegram library after 30 days. Any still on this iPhone stay there.")
        }
        .alert("Delete \(selection.count) from this iPhone?", isPresented: $confirmDeviceDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete from iPhone", role: .destructive) { Task { await deleteFromDevice() } }
        } message: {
            let notBacked = selectedEntries.filter { $0.asset != nil && $0.badge != .backedUp }.count
            Text(notBacked > 0
                 ? "\(notBacked) of these are NOT backed up yet and would be lost after Recently Deleted is emptied."
                 : "They stay in your Telegram library and in Memvo as cloud items.")
        }
    }

    private var selectedEntries: [GalleryEntry] { entries.filter { selection.contains($0.id) } }

    private var filterSize: Int {
        switch filter {
        case .album(_, let ids)?: return ids.count
        case nil: return -1
        default: return 0
        }
    }

    // MARK: - Grid

    /// Changes whenever the sections the grid shows change (library reload, regrouping on pinch, filter results).
    private var gridVersion: Int {
        filter == nil ? model.sectionsRevision : filteredVersion
    }

    private var grid: some View {
        NativePhotoGrid(entries: entries, sections: sections, dataVersion: gridVersion, columns: $columns, grouping: grouping,
                        selecting: selecting, selection: $selection, scrubTarget: scrubTarget, scrubToken: scrubToken, motion: motion,
                        onLongPress: { entry in
                            Haptics.tap()
                            selecting = true
                            selection.insert(entry.id)
                        },
                        onViewerPage: { viewerCurrentId = $0 })
            .ignoresSafeArea(edges: .bottom)
            .onAppear { NotificationCenter.default.post(name: .galleryDidAppear, object: nil) }
            .safeAreaInset(edge: .top, spacing: 0) {
                if model.authorization == .limited && filter == nil { limitedBanner.padding(.horizontal).padding(.vertical, 6).background(.bar) }
            }
            .overlay(alignment: .trailing) {
                if sections.count > 3 {
                    DateScrubber(sections: sections, motion: motion) { id in
                        scrubTarget = id
                        scrubToken += 1
                    }
                }
            }
    }

    private var limitedBanner: some View {
        HStack {
            Label("Memvo can only see the photos you selected.", systemImage: "photo.badge.exclamationmark")
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
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        case .notDetermined:
            EmptyStateView(systemImage: "photo.on.rectangle", title: "Allow photo access",
                           message: "Memvo needs access to back up your library.", actionTitle: "Allow") {
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
                    Divider()
                    Button { showLegend = true } label: { Label("What the icons mean", systemImage: "info.circle") }
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
        let notBackedUp = onDevice.filter { [.phoneOnly, .failed, .waiting].contains($0.badge) }
        return HStack {
            Button { Task { await shareSelection(chosen) } } label: { Label("Share", systemImage: "square.and.arrow.up") }
                .disabled(chosen.isEmpty)
            Spacer()
            Button { Task { await download(downloadable) } } label: { Label("Save", systemImage: "square.and.arrow.down") }
                .disabled(downloadable.isEmpty)
            Spacer()
            Button { backUp(notBackedUp) } label: { Label("Back up", systemImage: "icloud.and.arrow.up") }
                .disabled(notBackedUp.isEmpty)
                .accessibilityLabel("Back up \(notBackedUp.count) to the cloud")
            Spacer()
            Text("\(selection.count)").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
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

    private func backUp(_ chosen: [GalleryEntry]) {
        let ids = chosen.compactMap { $0.asset?.localIdentifier }
        Task {
            let n = await Task.detached { AppEnvironment.shared.engine.enqueue(localIdentifiers: ids) }.value
            Haptics.success()
            selecting = false
            selection.removeAll()
            ContinuedBackup.start()
            alert = GalleryAlert(title: "Backing up \(n) item\(n == 1 ? "" : "s")", message: "Progress is on the Backup tab.")
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

/// The only scroll bar: a thumb that follows the scroll position, appears while scrolling, and can be
/// dragged to jump through dates with the month shown beside it (like Photos and Google Photos).
struct DateScrubber: View {
    let sections: [GallerySection]
    let motion: GridMotion
    let jump: (String) -> Void
    @State private var dragging = false
    @State private var dragFraction: CGFloat = 0
    @State private var label = ""
    @State private var lastId = ""
    @State private var visible = false
    @State private var hideTask: Task<Void, Never>?

    private let thumbHeight: CGFloat = 44

    var body: some View {
        GeometryReader { geo in
            let track = max(geo.size.height - thumbHeight - 16, 1)
            let f = dragging ? dragFraction : min(max(motion.fraction, 0), 1)
            ZStack(alignment: .topTrailing) {
                HStack(spacing: 8) {
                    if dragging {
                        Text(label)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(.regularMaterial, in: Capsule())
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                    Capsule()
                        .fill(.regularMaterial)
                        .overlay(Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary))
                        .frame(width: 26, height: thumbHeight)
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                }
                .padding(.trailing, 4)
                .offset(y: 8 + f * track)
                .opacity(visible || dragging ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .contentShape(Rectangle().inset(by: 0))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard visible || dragging else { return }
                        if !dragging { withAnimation(.easeOut(duration: 0.15)) { dragging = true } }
                        dragFraction = min(max((v.location.y - 8 - thumbHeight / 2) / track, 0), 1)
                        let s = sections[min(sections.count - 1, Int(dragFraction * CGFloat(sections.count)))]
                        label = s.title
                        if s.id != lastId {
                            lastId = s.id
                            jump(s.id)
                            UISelectionFeedbackGenerator().selectionChanged()
                        }
                    }
                    .onEnded { _ in
                        withAnimation(.easeOut(duration: 0.2)) { dragging = false }
                        scheduleHide()
                    }
            )
            .allowsHitTesting(visible || dragging)
        }
        .frame(width: dragging ? 220 : 44)
        .onChange(of: motion.isScrolling) { _, now in
            if now { hideTask?.cancel(); withAnimation(.easeOut(duration: 0.15)) { visible = true } } else { scheduleHide() }
        }
        .accessibilityLabel("Date scrubber")
        .accessibilityHint("Drag to jump to a date")
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, !dragging else { return }
            withAnimation(.easeIn(duration: 0.3)) { visible = false }
        }
    }
}

/// Values that change every frame while scrolling or pinching (Observation: only readers redraw).
@Observable final class GridMotion {
    var fraction: CGFloat = 0
    var isScrolling = false
}
