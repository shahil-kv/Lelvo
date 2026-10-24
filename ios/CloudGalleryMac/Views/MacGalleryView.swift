import SwiftUI
import Photos
import UniformTypeIdentifiers
import CloudGalleryCore

/// The photo grid for one sidebar item. Click opens the viewer (zooming out of the tile); Select (or ⌘/⇧-click)
/// picks several. Zoom slider, arrow keys, context menus and drag-out to Finder.
struct MacGalleryView: View {
    static let space = "macGallery"

    let item: SidebarItem
    let filter: GalleryFilter?

    @EnvironmentObject private var model: GalleryModel
    @EnvironmentObject private var navigation: MacNavigation
    @EnvironmentObject private var activity: BackupActivity
    @EnvironmentObject private var index: MacLibraryIndex
    @AppStorage(MacPrefs.tileSize) private var tileSize: Double = 150
    @StateObject private var toast = ToastCenter()

    @State private var flat: [GalleryEntry] = []
    @State private var sections: [GallerySection] = []
    @State private var positions: [String: Int] = [:]
    @State private var ready = false
    @State private var selection = Set<String>()
    @State private var selecting = false
    @State private var anchorId: String?
    @State private var cursorId: String?
    @State private var columns = 5
    @State private var viewerId: String?
    @State private var showInfo = false
    @State private var confirmCloudDelete: [GalleryEntry] = []
    @State private var confirmMacDelete: [GalleryEntry] = []
    @State private var commandToken: UUID?
    @State private var scrollRequest: String?
    @FocusState private var gridFocused: Bool

    private let spacing: CGFloat = 3
    private let gutter: CGFloat = 16
    static let tileRange: ClosedRange<Double> = 64...380

    private var grouping: GalleryModel.Grouping { tileSize >= 110 ? .day : (tileSize >= 76 ? .month : .year) }
    private var selectedEntries: [GalleryEntry] { flat.filter { selection.contains($0.id) } }
    private var viewerEntry: GalleryEntry? { viewerId.flatMap { positions[$0] }.map { flat[$0] } }

    /// The item(s) the toolbar, inspector and menus act on: the viewer's item, else the selection.
    private var targets: [GalleryEntry] {
        if let viewerEntry { return [viewerEntry] }
        if selecting { return selectedEntries }
        return cursorId.flatMap { positions[$0] }.map { [flat[$0]] } ?? []
    }

    private struct DataKey: Equatable {
        let revision: Int
        let item: SidebarItem
        let filterSize: Int
        let grouping: GalleryModel.Grouping
    }

    var body: some View {
        ZStack {
            content
                .allowsHitTesting(viewerId == nil)
                .accessibilityHidden(viewerId != nil)
            if viewerId != nil {
                MacViewer(entries: flat, currentId: $viewerId, onClose: closeViewer)
                    .zIndex(1)
            }
        }
        .coordinateSpace(name: Self.space)
        .onChange(of: viewerId) { _, id in
            // Keep the grid under the viewer on the current item, so closing zooms back into the right tile.
            if let id { scrollRequest = id }
        }
        .overlay(alignment: .bottom) { bottomOverlay }
        .navigationTitle(viewerEntry.map { Format.date($0.date, style: .long, time: .none) } ?? item.title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .inspector(isPresented: $showInfo) {
            MacInfoPanel(entries: targets)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
        }
        .task(id: DataKey(revision: model.revision, item: item, filterSize: filterSize, grouping: grouping)) { await recompute() }
        .onAppear { subscribeCommands() }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .debugOpenIndex)) { note in
            if let i = note.object as? Int, flat.indices.contains(i) { open(flat[i]) }
        }
        #endif
        .onDisappear { commandToken.map(navigation.commands.unsubscribe) }
        .alert("Delete \(confirmCloudDelete.count) item\(confirmCloudDelete.count == 1 ? "" : "s") from your backup?",
               isPresented: Binding(get: { !confirmCloudDelete.isEmpty }, set: { if !$0 { confirmCloudDelete = [] } })) {
            Button("Cancel", role: .cancel) {}
            Button("Delete from Backup", role: .destructive) {
                let entries = confirmCloudDelete
                Task { await MacActions.deleteFromCloud(entries, toast: toast); afterDelete(entries) }
            }
        } message: {
            Text("They're removed from your Telegram library. Any still in Photos on this Mac stay there.")
        }
        .alert("Delete \(confirmMacDelete.count) item\(confirmMacDelete.count == 1 ? "" : "s") from this Mac?",
               isPresented: Binding(get: { !confirmMacDelete.isEmpty }, set: { if !$0 { confirmMacDelete = [] } })) {
            Button("Cancel", role: .cancel) {}
            Button("Delete from Mac", role: .destructive) {
                let entries = confirmMacDelete
                Task { await MacActions.deleteFromMac(entries, toast: toast) }
            }
        } message: {
            let unsafe = EntryActions(entries: confirmMacDelete).unsafeOnMac
            Text(unsafe > 0
                 ? "\(unsafe) of these are NOT backed up yet and will be lost once Recently Deleted is emptied."
                 : "They stay in your Telegram library and in CloudGallery as cloud items.")
        }
    }

    private var filterSize: Int {
        if case .album(_, let ids)? = filter { return ids.count }
        return -1
    }

    private var subtitle: String {
        if let e = viewerEntry {
            return [Format.date(e.date, style: .none, time: .short), e.badge.label].joined(separator: " · ")
        }
        guard ready else { return "" }
        let videos = flat.lazy.filter(\.isVideo).count
        let photos = flat.count - videos
        var parts: [String] = []
        if photos > 0 { parts.append("\(photos.formatted()) Photo\(photos == 1 ? "" : "s")") }
        if videos > 0 { parts.append("\(videos.formatted()) Video\(videos == 1 ? "" : "s")") }
        if selecting { parts.append("\(selection.count.formatted()) selected") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if !model.loaded || !ready {
            ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if flat.isEmpty {
            emptyState
        } else {
            grid
        }
    }

    private var grid: some View {
        GeometryReader { geo in
            let width = geo.size.width - gutter * 2
            let cols = max(1, Int((width + spacing) / (CGFloat(tileSize) + spacing)))
            let side = max(24, floor((width - spacing * CGFloat(cols - 1)) / CGFloat(cols)))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: spacing), count: cols),
                              spacing: spacing, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections) { section in
                            Section {
                                ForEach(section.entries) { entry in cell(entry, side: side) }
                            } header: {
                                MacSectionHeader(section: section, grouping: grouping, selected: section.entries.filter { selection.contains($0.id) }.count) {
                                    toggleSection(section)
                                }
                                .id("header-\(section.id)")
                            }
                        }
                    }
                    .padding(.horizontal, gutter)
                    .padding(.bottom, 80)
                    .background {
                        // Clicking empty space clears the selection, like Finder and Photos.
                        Color.clear.contentShape(Rectangle()).onTapGesture { clearSelection() }
                    }
                }
                .onChange(of: cols, initial: true) { _, c in columns = c }
                .onChange(of: scrollRequest) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id, anchor: nil)
                    scrollRequest = nil
                }
            }
        }
        .focusable()
        .focused($gridFocused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            moveCursor(press.key, extend: press.modifiers.contains(.shift))
            return .handled
        }
        .onKeyPress(keys: [.space, .return]) { _ in
            guard let id = cursorId ?? selection.first, let i = positions[id] else { return .ignored }
            if selecting {
                if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            } else {
                open(flat[i])
            }
            return .handled
        }
        .onKeyPress(.escape) { selecting ? endSelecting() : clearSelection(); return .handled }
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            let cloud = EntryActions(entries: targets).inCloud
            guard !cloud.isEmpty else { return .ignored }
            confirmCloudDelete = cloud
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "a")) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            selectAll()
            return .handled
        }
        .onAppear { gridFocused = true }
    }

    private func cell(_ entry: GalleryEntry, side: CGFloat) -> some View {
        MacThumbnailCell(entry: entry, side: side, selecting: selecting, selected: selection.contains(entry.id),
                         cursor: cursorId == entry.id && gridFocused && !selecting)
            .id(entry.id)
            .onTapGesture { click(entry) }
            .contextMenu { contextMenu(for: entry) }
            .onDrag { dragProvider(entry) }
    }

    @ViewBuilder private var emptyState: some View {
        if filter != nil {
            ContentUnavailableView {
                Label("Nothing in \(item.title)", systemImage: item.symbol)
            } description: {
                Text(item == .notBackedUp ? "Everything in Photos on this Mac is in your Telegram backup." : "Items appear here as you add and back up photos.")
            }
        } else {
            switch model.authorization {
            case .denied, .restricted:
                ContentUnavailableView {
                    Label("No access to Photos", systemImage: "photo.badge.exclamationmark")
                } description: {
                    Text("Allow CloudGallery in System Settings → Privacy & Security → Photos to back up and browse this Mac's library. Your cloud items appear here after a restore.")
                } actions: {
                    Button("Open System Settings") { PlatformActions.openPhotoSettings() }.buttonStyle(.borderedProminent)
                }
            case .notDetermined:
                ContentUnavailableView {
                    Label("Allow access to Photos", systemImage: "photo.on.rectangle")
                } description: {
                    Text("CloudGallery shows your Photos library and your Telegram backup in one timeline.")
                } actions: {
                    Button("Allow Access") {
                        Task {
                            _ = await PhotoLibraryService.requestAuthorization()
                            model.registerForChangesIfNeeded()
                            await model.reload()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            default:
                ContentUnavailableView("No photos yet", systemImage: "photo.on.rectangle",
                                       description: Text("Photos on this Mac and everything in your Telegram backup show up here."))
            }
        }
    }

    @ViewBuilder private var bottomOverlay: some View {
        VStack(spacing: 10) {
            if let t = toast.current {
                ToastView(toast: t).transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if viewerId == nil && selecting {
                selectionBar.transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 18)
        .animation(.spring(duration: 0.3, bounce: 0.15), value: toast.current)
        .animation(.spring(duration: 0.3, bounce: 0.15), value: selecting)
    }

    // MARK: - Selection bar

    private var selectionBar: some View {
        let actions = EntryActions(entries: selectedEntries)
        return HStack(spacing: 6) {
            Button { endSelecting() } label: { Image(systemName: "xmark").frame(width: 22, height: 22) }
                .buttonStyle(.borderless)
                .help("Done (Esc)")
            Text(selection.isEmpty ? "Select items" : "\(selection.count.formatted()) selected")
                .font(.callout.weight(.semibold).monospacedDigit())
                .padding(.trailing, 6)
            Divider().frame(height: 18)
            Button(selection.count == flat.count ? "Deselect All" : "Select All") {
                if selection.count == flat.count { selection.removeAll() } else { selectAll() }
            }
            .buttonStyle(.borderless)
            barButton("Share", "square.and.arrow.up") { Task { await MacActions.share(selectedEntries, toast: toast) } }
                .disabled(selection.isEmpty)
            barButton("Export", "square.and.arrow.down.on.square") { Task { await MacActions.export(selectedEntries, toast: toast) } }
                .disabled(selection.isEmpty)
            if !actions.downloadable.isEmpty {
                barButton("Save to Photos", "photo.badge.plus") { Task { await MacActions.saveToPhotos(actions.downloadable, toast: toast) } }
            }
            if !actions.notBackedUp.isEmpty {
                barButton("Back Up \(actions.notBackedUp.count)", "icloud.and.arrow.up") {
                    Task { await MacActions.backUp(actions.notBackedUp, toast: toast) }
                }
                .foregroundStyle(Color.accentColor)
            }
            Menu {
                deleteButtons(actions)
            } label: {
                Image(systemName: "trash")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28)
            .disabled(actions.inCloud.isEmpty && actions.onMac.isEmpty)
            .help("Delete")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .overlay(Capsule().strokeBorder(.separator.opacity(0.5)))
        .shadow(color: .black.opacity(0.2), radius: 18, y: 8)
    }

    private func barButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).labelStyle(.titleAndIcon).padding(.horizontal, 4)
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
    }

    @ViewBuilder private func deleteButtons(_ actions: EntryActions) -> some View {
        Button("Delete from Backup…", systemImage: "icloud.slash") { confirmCloudDelete = actions.inCloud }
            .disabled(actions.inCloud.isEmpty)
        Button("Delete from This Mac…", systemImage: "trash") { confirmMacDelete = actions.onMac }
            .disabled(actions.onMac.isEmpty)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if viewerId != nil {
            ToolbarItem(placement: .navigation) {
                Button { closeViewer() } label: { Label("Back", systemImage: "chevron.left") }
                    .help("Back to \(item.title) (Esc)")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if viewerId == nil {
                ZoomControl(tileSize: $tileSize, range: Self.tileRange)
                Spacer()
                Button(selecting ? "Done" : "Select") { selecting ? endSelecting() : startSelecting() }
                    .help(selecting ? "Stop selecting (Esc)" : "Select several photos")
                    .disabled(flat.isEmpty)
            }
            backupButton
            let actions = EntryActions(entries: targets)
            Button { Task { await MacActions.share(targets, toast: toast) } } label: { Label("Share", systemImage: "square.and.arrow.up") }
                .disabled(targets.isEmpty)
                .help("Share")
            if viewerId != nil {
                if !actions.downloadable.isEmpty {
                    Button { Task { await MacActions.saveToPhotos(actions.downloadable, toast: toast) } } label: {
                        Label("Save to Photos", systemImage: "photo.badge.plus")
                    }
                    .help("Save to Photos on this Mac")
                }
                Menu {
                    Button("Export…", systemImage: "square.and.arrow.down.on.square") { Task { await MacActions.export(targets, toast: toast) } }
                    Divider()
                    deleteButtons(actions)
                } label: { Label("More", systemImage: "ellipsis.circle") }
                .menuIndicator(.hidden)
            }
            Button { showInfo.toggle() } label: { Label("Info", systemImage: "info.circle") }
                .help("Show Info (⌘I)")
        }
    }

    @ViewBuilder private var backupButton: some View {
        let actions = EntryActions(entries: targets)
        if !actions.notBackedUp.isEmpty {
            Button { Task { await MacActions.backUp(actions.notBackedUp, toast: toast) } } label: {
                Label(actions.notBackedUp.count == 1 ? "Back Up" : "Back Up \(actions.notBackedUp.count)", systemImage: "icloud.and.arrow.up")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .help("Back up to your Telegram library")
        } else if activity.isRunning {
            Button { navigation.selection = .backup } label: {
                HStack(spacing: 6) {
                    ProgressView(value: Double(activity.done), total: Double(max(activity.total, 1)))
                        .progressViewStyle(.circular).controlSize(.mini)
                    Text(activity.total > 0 ? "\(activity.remaining.formatted()) left" : "Preparing…").monospacedDigit()
                }
            }
            .help("Backing up — open Backup")
        } else if (index.counts[.notBackedUp] ?? 0) > 0 && viewerId == nil {
            Button { ContinuedBackup.start(everything: true) } label: {
                Label("Back Up Now", systemImage: "icloud.and.arrow.up").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .help("Back up everything that isn't in your Telegram library yet (⌘B)")
        }
    }

    // MARK: - Context menu and drag

    @ViewBuilder private func contextMenu(for entry: GalleryEntry) -> some View {
        let group = selection.contains(entry.id) ? selectedEntries : [entry]
        let actions = EntryActions(entries: group)
        if group.count == 1 {
            Button("Open", systemImage: "arrow.up.left.and.arrow.down.right") { open(entry) }
            Button("Get Info", systemImage: "info.circle") { cursorId = entry.id; if !selecting { selection = [entry.id] }; showInfo = true }
            Divider()
        }
        Button("Share…", systemImage: "square.and.arrow.up") { Task { await MacActions.share(group, toast: toast) } }
        Button("Export \(group.count == 1 ? "" : "\(group.count) Items ")to Folder…", systemImage: "square.and.arrow.down.on.square") {
            Task { await MacActions.export(group, toast: toast) }
        }
        if !actions.downloadable.isEmpty {
            Button("Save to Photos", systemImage: "photo.badge.plus") { Task { await MacActions.saveToPhotos(actions.downloadable, toast: toast) } }
        }
        if !actions.notBackedUp.isEmpty {
            Button("Back Up \(actions.notBackedUp.count == 1 ? "" : "\(actions.notBackedUp.count) Items")", systemImage: "icloud.and.arrow.up") {
                Task { await MacActions.backUp(actions.notBackedUp, toast: toast) }
            }
        }
        Divider()
        deleteButtons(actions)
    }

    private func dragProvider(_ entry: GalleryEntry) -> NSItemProvider {
        let provider = NSItemProvider()
        let name: String = {
            if let asset = entry.asset { return PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "Photo" }
            return entry.item.map(CloudMediaService.displayedFilename) ?? "Photo"
        }()
        provider.suggestedName = (name as NSString).deletingPathExtension
        let type = UTType(filenameExtension: (name as NSString).pathExtension) ?? (entry.isVideo ? .movie : .image)
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            Task {
                do { completion(try await GalleryActions.shareableFile(for: entry), false, nil) }
                catch { completion(nil, false, error) }
            }
            return nil
        }
        return provider
    }

    // MARK: - Data

    private func recompute() async {
        let entries = model.entries
        let filter = self.filter
        let grouping = self.grouping
        let (flat, sections) = await Task.detached(priority: .userInitiated) { () -> ([GalleryEntry], [GallerySection]) in
            let flat = filter.map { f in entries.filter(f.matches) } ?? entries
            return (flat, GalleryModel.group(flat, grouping: grouping))
        }.value
        guard !Task.isCancelled else { return }
        var positions: [String: Int] = [:]
        positions.reserveCapacity(flat.count)
        for (i, e) in flat.enumerated() { positions[e.id] = i }
        self.flat = flat
        self.sections = sections
        self.positions = positions
        selection = selection.filter { positions[$0] != nil }
        if let v = viewerId, positions[v] == nil { viewerId = nil }
        ready = true
    }

    // MARK: - Selection

    /// Click opens, like Photos on iPhone. In Select mode (or with ⌘ / ⇧) it picks instead.
    private func click(_ entry: GalleryEntry) {
        gridFocused = true
        let flags = NSEvent.modifierFlags
        if !selecting && (flags.contains(.command) || flags.contains(.shift)) {
            selecting = true
            selection = cursorId.map { [$0] } ?? []
            anchorId = cursorId
        }
        guard selecting else {
            open(entry)
            return
        }
        if flags.contains(.shift), let anchor = anchorId, let a = positions[anchor], let b = positions[entry.id] {
            selection.formUnion(flat[min(a, b)...max(a, b)].map(\.id))
        } else {
            if selection.contains(entry.id) { selection.remove(entry.id) } else { selection.insert(entry.id) }
            anchorId = entry.id
        }
        cursorId = entry.id
    }

    private func startSelecting() {
        selection.removeAll()
        anchorId = nil
        withAnimation(.snappy) { selecting = true }
    }

    private func endSelecting() {
        withAnimation(.snappy) { selecting = false }
        selection.removeAll()
        anchorId = nil
    }

    private func clearSelection() {
        selection.removeAll()
        anchorId = nil
        cursorId = nil
    }

    private func selectAll() {
        selecting = true
        selection = Set(flat.map(\.id))
    }

    private func toggleSection(_ section: GallerySection) {
        selecting = true
        let ids = Set(section.entries.map(\.id))
        if ids.isSubset(of: selection) { selection.subtract(ids) } else { selection.formUnion(ids) }
    }

    private func moveCursor(_ key: KeyEquivalent, extend: Bool) {
        guard !flat.isEmpty else { return }
        let current = (cursorId ?? selection.first).flatMap { positions[$0] }
        let next: Int
        if let i = current {
            switch key {
            case .leftArrow: next = max(0, i - 1)
            case .rightArrow: next = min(flat.count - 1, i + 1)
            case .upArrow: next = max(0, i - columns)
            default: next = min(flat.count - 1, i + columns)
            }
        } else {
            next = 0
        }
        let id = flat[next].id
        if extend {
            if !selecting { selecting = true; anchorId = cursorId ?? id }
            if let anchor = anchorId, let a = positions[anchor] {
                selection = Set(flat[min(a, next)...max(a, next)].map(\.id))
            }
        } else if !selecting {
            anchorId = id
        }
        cursorId = id
        scrollRequest = id
    }

    // MARK: - Viewer

    private func open(_ entry: GalleryEntry) {
        cursorId = entry.id
        viewerId = entry.id
    }

    private func closeViewer() {
        guard let id = viewerId else { return }
        viewerId = nil
        cursorId = id
        gridFocused = true
    }

    private func afterDelete(_ entries: [GalleryEntry]) {
        let ids = Set(entries.map(\.id))
        selection.subtract(ids)
        if let v = viewerId, ids.contains(v), viewerEntry?.isCloudOnly == true {
            // The page is gone with the item: move to its neighbour like Photos does.
            if let i = positions[v] { viewerId = flat.indices.contains(i + 1) ? flat[i + 1].id : (i > 0 ? flat[i - 1].id : nil) }
        }
    }

    private func subscribeCommands() {
        guard commandToken == nil else { return }
        commandToken = navigation.commands.subscribe { command in
            switch command {
            case .zoomIn:
                guard viewerId == nil else { return false }
                withAnimation(.snappy) { tileSize = min(Self.tileRange.upperBound, tileSize * 1.25) }
            case .zoomOut:
                guard viewerId == nil else { return false }
                withAnimation(.snappy) { tileSize = max(Self.tileRange.lowerBound, tileSize / 1.25) }
            case .toggleInfo: showInfo.toggle()
            case .selectAll: selectAll()
            case .find: return false
            }
            return true
        }
    }
}

/// − slider + like Photos' toolbar.
struct ZoomControl: View {
    @Binding var tileSize: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack(spacing: 6) {
            Button { withAnimation(.snappy) { tileSize = max(range.lowerBound, tileSize / 1.25) } } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.borderless)
            .help("Zoom Out (⌘−)")
            Slider(value: $tileSize, in: range)
                .controlSize(.small)
                .frame(width: 110)
            Button { withAnimation(.snappy) { tileSize = min(range.upperBound, tileSize * 1.25) } } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Zoom In (⌘+)")
        }
        .padding(.horizontal, 4)
    }
}

/// Date header like Photos: bold day/month/year, the count, and a Select button on hover.
private struct MacSectionHeader: View {
    let section: GallerySection
    let grouping: GalleryModel.Grouping
    let selected: Int
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(section.title)
                .font(grouping == .day ? .title3.weight(.semibold) : .title2.weight(.bold))
            Text(section.entries.count.formatted())
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            if hovering || selected > 0 {
                Button(selected == section.entries.count ? "Deselect" : "Select", action: toggle)
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One tile: thumbnail, video duration / Live badge, backup status, selection ring.
struct MacThumbnailCell: View {
    let entry: GalleryEntry
    let side: CGFloat
    var selecting = false
    let selected: Bool
    let cursor: Bool
    @State private var image: PlatformImage?
    @State private var failed = false
    @State private var hovering = false
    @Environment(\.displayScale) private var scale

    var body: some View {
        ZStack {
            Color.tileBackground
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .clipped()
                    .transition(.opacity)
            } else if failed {
                Image(systemName: entry.badge == .tooLarge ? "doc.badge.ellipsis" : "photo")
                    .font(.title2).foregroundStyle(.tertiary)
            }
        }
        .frame(width: side, height: side)
        .overlay {
            if hovering && !selected { Color.white.opacity(0.07) }
        }
        .overlay(alignment: .bottomLeading) {
            if side >= 56 {
                if entry.isVideo, let d = entry.duration {
                    Text(Duration.seconds(d).formatted(.time(pattern: .minuteSecond)))
                        .font(.caption2.monospacedDigit().weight(.semibold)).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 2).padding(5)
                } else if entry.isLive {
                    Image(systemName: "livephoto").font(.caption2.weight(.semibold)).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 2).padding(5)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            BadgeView(badge: entry.badge, tileSide: side).padding(side > 60 ? 4 : 2)
        }
        .overlay {
            if selected || cursor {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: selected ? 3 : 1.5)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if selecting && side >= 44 {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, selected ? Color.accentColor : .black.opacity(0.25))
                    .shadow(color: .black.opacity(0.35), radius: 2)
                    .padding(5)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .scaleEffect(selecting && selected ? 0.92 : 1)
        .animation(.spring(duration: 0.22, bounce: 0.2), value: selected)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(MacGalleryView.space)) } action: { rect in
            TileRegistry.shared.setFrame(rect, for: entry.id)
        }
        .onDisappear { TileRegistry.shared.setFrame(nil, for: entry.id) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.accessibilityLabel)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .task(id: ThumbRequest(id: entry.id, pixels: pixels)) { await load() }
    }

    /// Requests in 128-pixel steps, so dragging the zoom slider doesn't reload every frame.
    private var pixels: Int { (Int(side * scale) / 128 + 1) * 128 }

    private struct ThumbRequest: Equatable { let id: String; let pixels: Int }

    private func load() async {
        let env = AppEnvironment.shared
        if let asset = entry.asset {
            for await img in env.photos.thumbnails(for: asset, pixels: CGFloat(pixels)) {
                withAnimation(image == nil ? .easeOut(duration: 0.15) : nil) { image = img }
                TileRegistry.shared.setImage(img, for: entry.id)
            }
        } else if let item = entry.item {
            if let cached = env.media.cachedThumbnail(for: item) {
                image = cached
                TileRegistry.shared.setImage(cached, for: entry.id)
                return
            }
            do {
                let img = try await env.media.thumbnail(for: item)
                withAnimation(.easeOut(duration: 0.15)) { image = img }
                TileRegistry.shared.setImage(img, for: entry.id)
            } catch { failed = true }
        }
        if image == nil { failed = true }
    }
}
