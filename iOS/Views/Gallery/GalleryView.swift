import SwiftUI
import Photos
import PhotosUI
import LelvoCore

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
    @State private var confirmDelete = false
    @State private var addingToAlbum = false
    @State private var showLegend = false
    /// The item showing in the viewer (changes as the user swipes).
    @State private var viewerCurrentId: String?
    /// Per-frame scroll values live here, read only by the date scrubber, so nothing else redraws while scrolling.
    @State private var motion = GridMotion()
    @State private var scrubTarget: String?
    @State private var scrubToken = 0
    /// Bumped when the filtered timeline is recomputed, so the grid knows its data changed.
    @State private var filteredVersion = 0
    /// "Show Selected", like Photos: the items picked when it was tapped. Kept fixed while selecting, so unticking one
    /// doesn't make it jump out of the grid.
    @State private var shown: (entries: [GalleryEntry], sections: [GallerySection])?
    @State private var shownVersion = 0
    /// Bumped on every Show Selected tap, so a slow grouping can't switch it back on after the user turned it off.
    @State private var shownRequest = 0

    private var grouping: GalleryModel.Grouping { GalleryModel.Grouping(columns: columns) }
    /// The timeline is already grouped by the model; filtered views (albums, Videos…) are computed once per
    /// library change off the main thread instead of on every render.
    private var entries: [GalleryEntry] { shown?.entries ?? (filter == nil ? model.entries : filtered.entries) }
    private var sections: [GallerySection] { shown?.sections ?? (filter == nil ? model.sections : filtered.sections) }
    @State private var filtered: (entries: [GalleryEntry], sections: [GallerySection]) = ([], [])

    private struct FilterKey: Equatable { let revision: Int; let grouping: GalleryModel.Grouping; let size: Int }

    var body: some View {
        if embedInNavigation { NavigationStack { content.settingsButton(hidden: selecting) } } else { content }
    }

    private var content: some View {
        Group {
            if !model.loaded {
                LibrarySkeleton(columns: columns)
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
        .navigationTitle(selecting ? selectionTitle : (filter?.title ?? "Photos"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        // Like Photos: once something is picked, the tabs make way for the selection buttons.
        .toolbar(hasSelection ? .hidden : .visible, for: .tabBar)
        .sheet(isPresented: $showLegend) { BadgeLegendView() }
        .safeAreaInset(edge: .bottom) {
            if hasSelection { selectionBar.transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .motion(Motion.standard, value: hasSelection)
        .onChange(of: hasSelection) { _, picked in if !picked { shown = nil } }
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
        .onChange(of: columns) { _, c in
            model.setGrouping(GalleryModel.Grouping(columns: c))
            // Pinching keeps the picked-only view; its days or months are regrouped for the new size.
            if let list = shown?.entries { showOnly(list) }
        }
        .onAppear { model.setGrouping(grouping) }
        .sheet(item: $share) { ActivityView(items: $0.urls).presentationDetents([.medium, .large]) }
        .alert(item: $alert) { a in Alert(title: Text(a.title), message: Text(a.message)) }
        .sheet(isPresented: $addingToAlbum) {
            AddToAlbumView(count: selection.count) { id, title in Task { await addToAlbum(id, title) } }
        }
    }

    /// From the live timeline, not the Show Selected snapshot, so badges, backup state and favourites stay current.
    private var selectedEntries: [GalleryEntry] {
        guard !selection.isEmpty else { return [] }
        return (filter == nil ? model.entries : filtered.entries).filter { selection.contains($0.id) }
    }

    private var hasSelection: Bool { selecting && !selection.isEmpty }

    private var selectionTitle: String { selection.isEmpty ? "Select Items" : "\(selection.count.formatted()) Selected" }

    private var deleteTitle: String { "Delete \(selection.count.formatted()) item\(selection.count == 1 ? "" : "s")?" }

    /// Short, like Photos. Anything not backed up yet is named first, so "Remove" is never read as safe for it.
    private func deleteMessage(_ chosen: [GalleryEntry]) -> String {
        let onDevice = chosen.filter { $0.asset != nil }
        let notBacked = onDevice.filter { $0.badge != .backedUp }.count
        var lines: [String] = []
        if notBacked > 0 {
            lines.append("\(notBacked.formatted()) \(notBacked == 1 ? "isn't" : "aren't") backed up yet and will be lost once Recently Deleted in Photos is emptied.")
        } else if !onDevice.isEmpty {
            lines.append("Remove from This iPhone keeps your backup.")
        }
        lines.append("Deleted backups stay in Recently Deleted for 30 days.")
        return lines.joined(separator: " ")
    }

    private var filterSize: Int {
        switch filter {
        case .album(_, let ids)?: return ids.count
        // A new search with as many results must still refresh the grid.
        case .matching(_, let ids)?: return ids.hashValue
        case nil: return -1
        default: return 0
        }
    }

    // MARK: - Grid

    /// Changes whenever the sections the grid shows change (library reload, regrouping on pinch, filter results).
    private var gridVersion: Int {
        // Negative so it never matches a library or filter version.
        if shown != nil { return -1 - shownVersion }
        return filter == nil ? model.sectionsRevision : filteredVersion
    }

    private var grid: some View {
        NativePhotoGrid(entries: entries, sections: sections, dataVersion: gridVersion, columns: $columns, grouping: grouping,
                        selecting: selecting, selection: $selection, scrubTarget: scrubTarget, scrubToken: scrubToken, motion: motion,
                        onLongPress: { entry in
                            Haptics.press()
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
            Label("Lelvo can only see the photos you selected.", systemImage: "photo.badge.exclamationmark")
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
                           message: "Lelvo needs access to back up your library.", actionTitle: "Allow") {
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
        if selecting {
            // Tapping the count shows only what's picked, so the bottom middle can hold Back Up.
            ToolbarItem(placement: .principal) {
                Button { toggleShowSelected() } label: {
                    HStack(spacing: 4) {
                        Text(selectionTitle).font(.headline).monospacedDigit()
                        if !selection.isEmpty {
                            Image(systemName: shown == nil ? "chevron.down" : "chevron.up")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(selection.isEmpty)
                .accessibilityHint(shown == nil ? "Shows only the selected items" : "Shows all items")
            }
            ToolbarItem(placement: .topBarTrailing) { moreMenu }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if selecting {
                Button { selecting = false; selection.removeAll() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Done")
            } else {
                Button("Select") { selecting = true; selection.removeAll() }
                    .disabled(entries.isEmpty)
            }
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

    /// Like Photos: three floating buttons over the grid. Share, Back Up (Lelvo's main job, in the brand colour) and
    /// Delete, which asks where in words, from the button itself.
    private var selectionBar: some View {
        let chosen = selectedEntries
        let notBackedUp = chosen.filter { $0.asset != nil && [.phoneOnly, .failed, .waiting].contains($0.badge) }
        let deletable = Self.canDelete(chosen)
        return HStack {
            Button { Task { await shareSelection(chosen) } } label: {
                Image(systemName: "square.and.arrow.up").frame(width: 50, height: 50)
            }
            .glassBackground(Circle())
            .accessibilityLabel("Share")
            Spacer(minLength: 12)
            if notBackedUp.isEmpty {
                Label("Backed Up", systemImage: "checkmark.icloud")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 22)
                    .frame(height: 50)
                    .glassBackground(Capsule())
                    .accessibilityLabel("All selected items are backed up")
            } else {
                Button { backUp(notBackedUp) } label: {
                    Label("Back Up \(notBackedUp.count.formatted())", systemImage: "icloud.and.arrow.up")
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .frame(height: 50)
                        .background(Color.accentColor, in: Capsule())
                        .contentShape(Capsule())
                }
                .accessibilityLabel("Back up \(notBackedUp.count) to your Telegram library")
            }
            Spacer(minLength: 12)
            Button(role: .destructive) { confirmDelete = true } label: {
                Image(systemName: "trash").frame(width: 50, height: 50)
            }
            .glassBackground(Circle())
            .disabled(!deletable)
            .accessibilityLabel("Delete")
            // On the button, so on iOS 26 it opens from the trash like Photos instead of floating mid-screen.
            .confirmationDialog(deleteTitle, isPresented: $confirmDelete, titleVisibility: .visible) {
                let onDevice = chosen.filter { $0.asset != nil }
                let backedUp = chosen.compactMap(\.item).filter { $0.status == .backedUp }
                if !onDevice.isEmpty {
                    Button("Remove \(onDevice.count.formatted()) from This iPhone", role: .destructive) { Task { await deleteFromDevice(onDevice) } }
                }
                // Keeps any copy on this iPhone: the only way to take something out of the backup but keep it here.
                if !backedUp.isEmpty && !onDevice.isEmpty {
                    Button("Delete \(backedUp.count.formatted()) from Backup Only", role: .destructive) { Task { await deleteFromBackup(backedUp) } }
                }
                Button("Delete Everywhere", role: .destructive) { Task { await deleteEverywhere() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(deleteMessage(chosen))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .font(.title3)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .motion(Motion.standard, value: notBackedUp.isEmpty)
    }

    /// Something on this iPhone, or a finished backup: the rest (uploads in progress) has nothing to delete yet.
    private static func canDelete(_ chosen: [GalleryEntry]) -> Bool {
        chosen.contains { $0.asset != nil || $0.item?.status == .backedUp }
    }

    private var moreMenu: some View {
        let chosen = selectedEntries
        let downloadable = chosen.filter { $0.isCloudOnly && $0.item?.isViewableFromCloud == true }
        let onDevice = chosen.compactMap(\.asset)
        let allFavorite = !onDevice.isEmpty && onDevice.allSatisfy(\.isFavorite)
        let allPicked = !entries.isEmpty && selection.count == entries.count
        return Menu {
            Button {
                if allPicked { selection.removeAll() } else { selection = Set(entries.map(\.id)) }
            } label: {
                Label(allPicked ? "Deselect All" : "Select All", systemImage: allPicked ? "circle" : "checkmark.circle")
            }
            Divider()
            Button { addingToAlbum = true } label: { Label("Add to Album", systemImage: "rectangle.stack.badge.plus") }
                .disabled(chosen.isEmpty)
            if !downloadable.isEmpty {
                Button { Task { await download(downloadable) } } label: {
                    Label("Save \(downloadable.count.formatted()) to iPhone", systemImage: "square.and.arrow.down")
                }
            }
            if !onDevice.isEmpty {
                Button { Task { await setFavorite(onDevice.map(\.localIdentifier), !allFavorite) } } label: {
                    Label(allFavorite ? "Unfavorite" : "Favorite", systemImage: allFavorite ? "heart.slash" : "heart")
                }
            }
            Divider()
            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete…", systemImage: "trash") }
                .disabled(!Self.canDelete(chosen))
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("More")
    }

    /// Grouping the picked items can take a moment with thousands selected, so it runs off the main actor.
    private func toggleShowSelected() {
        Haptics.selection()
        shownRequest += 1
        guard shown == nil else { shown = nil; return }
        let request = shownRequest
        let ids = selection
        let source = filter == nil ? model.entries : filtered.entries
        Task {
            let list = await Task.detached(priority: .userInitiated) { source.filter { ids.contains($0.id) } }.value
            guard request == shownRequest else { return }
            showOnly(list)
        }
    }

    private func showOnly(_ list: [GalleryEntry]) {
        let grouping = self.grouping
        let request = shownRequest
        Task {
            let sections = await Task.detached(priority: .userInitiated) { GalleryModel.group(list, grouping: grouping) }.value
            guard hasSelection, request == shownRequest else { return }
            shown = (list, sections)
            shownVersion += 1
        }
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

    private func deleteFromDevice(_ chosen: [GalleryEntry]) async {
        let ids = chosen.compactMap { $0.asset?.localIdentifier }
        do {
            try await AppEnvironment.shared.photos.deleteAssets(ids)
            Haptics.success()
            endSelecting()
            alert = GalleryAlert(title: "Removed from this iPhone",
                                 message: "Backed-up items are still in your Telegram library. Empty Recently Deleted in Photos to free the space now.")
        } catch let error as NSError where error.domain == PHPhotosErrorDomain && error.code == PHPhotosError.userCancelled.rawValue {
            // Cancelled in iOS's own confirmation: nothing happened.
        } catch {
            Haptics.error()
            alert = GalleryAlert(title: "Nothing was deleted", message: "Photos couldn't delete them. Try again from the Photos app.")
        }
    }

    private func deleteFromBackup(_ items: [MediaItem]) async {
        busyMessage = "Deleting…"
        defer { busyMessage = nil }
        do {
            try await GalleryActions.deleteFromCloud(items)
            Haptics.success()
            endSelecting()
            alert = GalleryAlert(title: "Deleted \(items.count.formatted()) from your backup",
                                 message: "Copies on this iPhone stay. You can get the backups back from Collections → Recently Deleted for 30 days.")
        } catch {
            Haptics.error()
            alert = GalleryAlert(title: "Nothing was deleted", message: "\(error.localizedDescription) Try again.")
        }
    }

    private func deleteEverywhere() async {
        let chosen = selectedEntries
        busyMessage = "Deleting…"
        defer { busyMessage = nil }
        do {
            let result = try await GalleryActions.deleteEverywhere(chosen)
            Haptics.success()
            endSelecting()
            if result.cloud > 0 {
                alert = GalleryAlert(title: "Deleted \(chosen.count.formatted()) item\(chosen.count == 1 ? "" : "s")",
                                     message: "You can get them back from Collections → Recently Deleted for 30 days.")
            }
        } catch let error as NSError where error.domain == PHPhotosErrorDomain && error.code == PHPhotosError.userCancelled.rawValue {
            // Cancelled in iOS's own confirmation: nothing was deleted anywhere.
        } catch {
            Haptics.error()
            alert = GalleryAlert(title: "Couldn't delete everything", message: "\(error.localizedDescription) Check what's left, then try again.")
        }
    }

    private func addToAlbum(_ albumId: String, _ title: String) async {
        let chosen = selectedEntries
        busyMessage = "Adding to \(title)…"
        defer { busyMessage = nil }
        do {
            let result = try await GalleryActions.addToAlbum(chosen, albumId: albumId)
            guard result.added > 0 else {
                Haptics.error()
                alert = GalleryAlert(title: "Nothing was added",
                                     message: "These items couldn't be saved from your Telegram library to Photos. Check your connection, open one to make sure it plays, then try again.")
                return
            }
            Haptics.success()
            endSelecting()
            alert = GalleryAlert(title: "Added \(result.added.formatted()) to “\(title)”",
                                 message: result.failed > 0
                                    ? "\(result.failed.formatted()) couldn't be saved from your Telegram library. Check your connection and try again."
                                    : "The album is in Photos on this iPhone.")
        } catch is CancellationError {
        } catch {
            Haptics.error()
            alert = GalleryAlert(title: "Nothing was added", message: error.localizedDescription)
        }
    }

    private func setFavorite(_ ids: [String], _ favorite: Bool) async {
        do {
            try await Task.detached { try await AppEnvironment.shared.photos.setFavorite(ids, favorite) }.value
            Haptics.success()
        } catch {
            Haptics.error()
            alert = GalleryAlert(title: "Couldn't change Favorites", message: "Photos didn't allow it. Try again from the Photos app.")
        }
    }

    private func endSelecting() {
        selecting = false
        selection.removeAll()
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
                            Haptics.selection()
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
            withAnimation(Motion.exit) { visible = false }
        }
    }
}

/// Values that change every frame while scrolling or pinching (Observation: only readers redraw).
@Observable final class GridMotion {
    var fraction: CGFloat = 0
    var isScrolling = false
}

/// Grey tiles in the grid's own layout while the library loads, so the screen doesn't jump when photos arrive. Shown
/// only after 0.3 s: a quick load shows nothing in between. One shared fade, no per-tile work.
private struct LibrarySkeleton: View {
    let columns: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let side = (geo.size.width - CGFloat(columns - 1) * 2) / CGFloat(max(columns, 1))
            let rows = Int(geo.size.height / max(side, 1)) + 1
            VStack(alignment: .leading, spacing: 2) {
                ForEach(0..<rows, id: \.self) { _ in
                    HStack(spacing: 2) {
                        ForEach(0..<columns, id: \.self) { _ in Color.tileBackground.frame(width: side, height: side) }
                    }
                }
            }
            .phaseAnimator(reduceMotion ? [true] : [false, true]) { grid, on in
                grid.opacity(on ? 1 : 0.55)
            } animation: { _ in .easeInOut(duration: 0.9) }
        }
        .opacity(shown ? 1 : 0)
        .task {
            try? await Task.sleep(for: .milliseconds(300))
            withAnimation(Motion.standard) { shown = true }
        }
        .accessibilityElement()
        .accessibilityLabel("Loading your library")
    }
}

private extension View {
    /// Liquid Glass on iOS 26, like the buttons over the grid in Photos; a material on earlier versions.
    @ViewBuilder func glassBackground<S: Shape>(_ shape: S) -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular.interactive(), in: shape).contentShape(shape)
        } else {
            background(.regularMaterial, in: shape).contentShape(shape)
        }
    }
}
