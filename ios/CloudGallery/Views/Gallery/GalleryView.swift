import SwiftUI
import Photos
import PhotosUI
import CloudGalleryCore

struct GalleryView: View {
    @StateObject private var model = GalleryModel()
    @AppStorage(Prefs.Key.gridColumns) private var columns = 4
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var viewerStart: GalleryEntry?
    @State private var share: ShareItems?
    @State private var busyMessage: String?
    @State private var alert: GalleryAlert?
    @State private var confirmCloudDelete = false
    @State private var pinchScale: CGFloat = 1

    private let spacing: CGFloat = 2

    var body: some View {
        NavigationStack {
            Group {
                if !model.loaded {
                    ProgressView("Loading your library…")
                } else if model.entries.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
            .navigationTitle("Photos")
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) { if selecting { selectionBar } }
            .overlay {
                if let busyMessage {
                    ProgressView(busyMessage)
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .task { await model.reload() }
        .onChange(of: columns) { _, c in model.setGrouping(byMonth: c >= 6) }
        .onAppear { model.setGrouping(byMonth: columns >= 6) }
        .fullScreenCover(item: $viewerStart) { start in
            ViewerView(entries: model.entries, startId: start.id)
        }
        .sheet(item: $share) { ActivityView(items: $0.urls).presentationDetents([.medium, .large]) }
        .alert(item: $alert) { a in Alert(title: Text(a.title), message: Text(a.message)) }
        .confirmationDialog("Delete \(selection.count) item(s) from your Telegram backup?", isPresented: $confirmCloudDelete,
                            titleVisibility: .visible) {
            Button("Delete from cloud", role: .destructive) { Task { await deleteFromCloud() } }
        } message: {
            Text("The messages are deleted from the channel and the index is updated. Items still on this iPhone stay there and will be backed up again on the next run.")
        }
    }

    // MARK: - Grid

    private var grid: some View {
        GeometryReader { geo in
            let side = (geo.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            ScrollView {
                if model.authorization == .limited { limitedBanner.padding(.horizontal) }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: spacing), count: columns),
                          spacing: spacing, pinnedViews: [.sectionHeaders]) {
                    ForEach(model.sections) { section in
                        Section {
                            ForEach(section.entries) { entry in
                                ThumbnailCell(entry: entry, side: side, selecting: selecting,
                                              selected: selection.contains(entry.id))
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
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                }
                .scaleEffect(pinchScale, anchor: .top)
            }
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { v in pinchScale = min(1.15, max(0.85, v.magnification)) }
                    .onEnded { v in
                        withAnimation(.spring(duration: 0.3)) {
                            pinchScale = 1
                            if v.magnification > 1.15 { columns = max(1, columns - 1) }
                            else if v.magnification < 0.85 { columns = min(8, columns + 1) }
                        }
                        Haptics.tap()
                    }
            )
            .refreshable { await model.reload() }
        }
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
            .disabled(model.entries.isEmpty)
        }
        if !selecting {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Picker("Columns", selection: $columns) {
                        ForEach([2, 3, 4, 5, 6, 7], id: \.self) { Text("\($0) columns").tag($0) }
                    }
                } label: { Image(systemName: "square.grid.3x3") }
                .accessibilityLabel("Grid size")
            }
        }
    }

    private var selectionBar: some View {
        let chosen = model.entries.filter { selection.contains($0.id) }
        let cloudItems = chosen.compactMap(\.item).filter { $0.status == .backedUp }
        let downloadable = chosen.filter { $0.isCloudOnly && $0.item?.isViewableFromCloud == true }
        return HStack {
            Button { Task { await shareSelection(chosen) } } label: { Label("Share", systemImage: "square.and.arrow.up") }
                .disabled(chosen.isEmpty)
            Spacer()
            Button { Task { await download(downloadable) } } label: { Label("Save", systemImage: "square.and.arrow.down") }
                .disabled(downloadable.isEmpty)
            Spacer()
            Text("\(selection.count) selected").font(.footnote).foregroundStyle(.secondary)
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
                                 message: "\(skipped) item(s) are larger than 20 MB or unavailable, so the app can't download them in version 1.")
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

    private func deleteFromCloud() async {
        let items = model.entries.filter { selection.contains($0.id) }.compactMap(\.item).filter { $0.status == .backedUp }
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
