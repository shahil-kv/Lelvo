import SwiftUI
import AppKit
import Photos
import UniformTypeIdentifiers
import MemvoCore

/// A context-menu entry built in SwiftUI and shown as an NSMenu.
struct GridMenuItem {
    var title: String
    var symbol: String?
    var enabled = true
    var isSeparator = false
    var action: () -> Void = {}

    static var separator: GridMenuItem { GridMenuItem(title: "", isSeparator: true) }
}

enum GridKey { case left, right, up, down, open, escape, delete, selectAll }

/// The photo grid on NSCollectionView, like Photos itself: tiles are recycled views drawn with Core Animation,
/// thumbnails load ahead of the scroll and off the main thread, and nothing runs per tile per frame.
struct MacPhotoGrid: NSViewRepresentable {
    let sections: [GallerySection]
    /// Bumped whenever `sections` changes, so unrelated SwiftUI updates never touch the collection view.
    let dataVersion: Int
    let tileSize: CGFloat
    let grouping: GalleryModel.Grouping
    let selecting: Bool
    let selection: Set<String>
    let cursorId: String?
    let scrollTarget: String?
    let scrollToken: Int
    var onClick: (GalleryEntry, NSEvent.ModifierFlags) -> Void
    var onKey: (GridKey, NSEvent.ModifierFlags) -> Void
    var menu: (GalleryEntry) -> [GridMenuItem]
    var onToggleSection: (GallerySection) -> Void
    var onMagnify: (CGFloat) -> Void
    var dragEntries: (GalleryEntry) -> [GalleryEntry]
    var onColumns: (Int) -> Void
    var onBackgroundClick: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = GridLayout()
        layout.onColumns = { [weak coordinator = context.coordinator] cols in coordinator?.parent.onColumns(cols) }
        let cv = GridCollectionView()
        cv.collectionViewLayout = layout
        cv.isSelectable = false
        cv.backgroundColors = [.windowBackgroundColor]
        cv.register(ThumbnailItem.self, forItemWithIdentifier: ThumbnailItem.identifier)
        cv.register(GridHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader, withIdentifier: GridHeader.identifier)
        cv.prefetchDataSource = context.coordinator
        cv.coordinator = context.coordinator
        context.coordinator.attach(cv, layout: layout)

        let scroll = NSScrollView()
        scroll.documentView = cv
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .windowBackgroundColor
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 90, right: 0)
        scroll.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        DispatchQueue.main.async { cv.window?.makeFirstResponder(cv) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewPrefetching, NSDraggingSource, NSFilePromiseProviderDelegate {
        var parent: MacPhotoGrid
        private weak var collectionView: GridCollectionView?
        private weak var layout: GridLayout?
        private var dataSource: NSCollectionViewDiffableDataSource<String, String>?
        private var entries: [String: GalleryEntry] = [:]
        private var sections: [String: GallerySection] = [:]
        private var appliedVersion = -1
        private var appliedScrollToken = -1
        private var appliedState: (selecting: Bool, selection: Set<String>, cursor: String?) = (false, [], nil)
        private nonisolated let promiseQueue: OperationQueue = {
            let q = OperationQueue()
            q.qualityOfService = .userInitiated
            q.maxConcurrentOperationCount = 2
            return q
        }()

        init(_ parent: MacPhotoGrid) { self.parent = parent }

        func attach(_ cv: GridCollectionView, layout: GridLayout) {
            collectionView = cv
            self.layout = layout
            layout.tileSize = parent.tileSize
            let ds = NSCollectionViewDiffableDataSource<String, String>(collectionView: cv) { [weak self] cv, indexPath, id in
                let item = cv.makeItem(withIdentifier: ThumbnailItem.identifier, for: indexPath)
                if let self, let thumb = item as? ThumbnailItem, let entry = self.entries[id] { self.configure(thumb, entry) }
                return item
            }
            ds.supplementaryViewProvider = { [weak self] cv, kind, indexPath in
                let view = cv.makeSupplementaryView(ofKind: kind, withIdentifier: GridHeader.identifier, for: indexPath)
                if let self, let header = view as? GridHeader,
                   let sectionId = self.dataSource?.snapshot().sectionIdentifiers[safe: indexPath.section],
                   let section = self.sections[sectionId] {
                    self.configure(header, section)
                }
                return view as? (NSView & NSCollectionViewElement)
            }
            dataSource = ds
            TileRegistry.shared.frameProvider = { [weak self] id in self?.windowRect(for: id) }
        }

        func detach() {
            TileRegistry.shared.frameProvider = nil
        }

        func update(_ p: MacPhotoGrid) {
            let old = parent
            parent = p
            guard let cv = collectionView, let layout else { return }
            if p.dataVersion != appliedVersion {
                appliedVersion = p.dataVersion
                apply(p.sections)
            }
            if layout.tileSize != p.tileSize {
                layout.tileSize = p.tileSize
                // After the new layout, sharpen thumbnails that are now shown bigger.
                DispatchQueue.main.async { [weak self] in self?.refreshVisible() }
            }
            if p.selecting != appliedState.selecting || p.selection != appliedState.selection || p.cursorId != appliedState.cursor {
                appliedState = (p.selecting, p.selection, p.cursorId)
                refreshVisible()
            }
            if old.grouping != p.grouping { refreshHeaders() }
            if p.scrollToken != appliedScrollToken {
                appliedScrollToken = p.scrollToken
                if let id = p.scrollTarget { scroll(to: id, in: cv) }
            }
        }

        private func apply(_ list: [GallerySection]) {
            var entries: [String: GalleryEntry] = [:]
            var sections: [String: GallerySection] = [:]
            var snapshot = NSDiffableDataSourceSnapshot<String, String>()
            snapshot.appendSections(list.map(\.id))
            for s in list {
                sections[s.id] = s
                snapshot.appendItems(s.entries.map(\.id), toSection: s.id)
                for e in s.entries { entries[e.id] = e }
            }
            self.entries = entries
            self.sections = sections
            dataSource?.apply(snapshot, animatingDifferences: false)
            // Same ids with new content (backup status changed): update the visible tiles in place.
            refreshVisible()
            refreshHeaders()
        }

        private func refreshVisible() {
            guard let cv = collectionView else { return }
            for item in cv.visibleItems() {
                guard let thumb = item as? ThumbnailItem, let ip = cv.indexPath(for: item),
                      let id = dataSource?.itemIdentifier(for: ip), let entry = entries[id] else { continue }
                configure(thumb, entry)
            }
            refreshHeaders()
        }

        private func refreshHeaders() {
            guard let cv = collectionView, let ds = dataSource else { return }
            let ids = ds.snapshot().sectionIdentifiers
            for ip in cv.indexPathsForVisibleSupplementaryElements(ofKind: NSCollectionView.elementKindSectionHeader) {
                guard let header = cv.supplementaryView(forElementKind: NSCollectionView.elementKindSectionHeader, at: ip) as? GridHeader,
                      let id = ids[safe: ip.section], let section = sections[id] else { continue }
                configure(header, section)
            }
        }

        private func configure(_ item: ThumbnailItem, _ entry: GalleryEntry) {
            let side = layout?.side ?? 150
            let scale = collectionView?.window?.backingScaleFactor ?? 2
            item.thumbnail.configure(entry: entry, side: side, pixels: ThumbnailPipeline.bucket(side * scale),
                                     selecting: parent.selecting, selected: parent.selection.contains(entry.id),
                                     cursor: !parent.selecting && parent.cursorId == entry.id && collectionView.map { $0.window?.firstResponder === $0 } == true)
            item.thumbnail.coordinator = self
        }

        private func configure(_ header: GridHeader, _ section: GallerySection) {
            let selectedCount = parent.selecting ? section.entries.reduce(0) { $0 + (parent.selection.contains($1.id) ? 1 : 0) } : 0
            header.configure(title: section.title, count: section.entries.count, large: parent.grouping != .day,
                             selecting: parent.selecting, allSelected: selectedCount == section.entries.count && selectedCount > 0) { [weak self] in
                self?.parent.onToggleSection(section)
            }
        }

        private func scroll(to id: String, in cv: NSCollectionView) {
            guard let ip = dataSource?.indexPath(for: id) else { return }
            cv.layoutSubtreeIfNeeded()
            let frame = cv.layoutAttributesForItem(at: ip)?.frame ?? .zero
            let visible = cv.visibleRect.insetBy(dx: 0, dy: 50)
            if !visible.contains(frame), let clip = cv.enclosingScrollView?.contentView {
                // Keep the tile clear of the pinned date header when scrolling up to it.
                let y = frame.minY < visible.minY ? frame.minY - 56 : frame.maxY - clip.bounds.height + 100
                clip.scroll(to: NSPoint(x: 0, y: max(0, min(y, cv.frame.height - clip.bounds.height))))
                cv.enclosingScrollView?.reflectScrolledClipView(clip)
            }
        }

        /// Tile rect in SwiftUI global coordinates (top-left origin of the window content), for the viewer's zoom.
        func windowRect(for id: String) -> CGRect? {
            guard let cv = collectionView, let ip = dataSource?.indexPath(for: id), let view = cv.item(at: ip)?.view,
                  let window = cv.window, let content = window.contentView else { return nil }
            let inWindow = view.convert(view.bounds, to: nil)
            let visible = cv.enclosingScrollView.map { $0.convert($0.bounds, to: nil) } ?? inWindow
            guard visible.intersects(inWindow) else { return nil }
            return CGRect(x: inWindow.minX, y: content.bounds.height - inWindow.maxY, width: inWindow.width, height: inWindow.height)
        }

        // MARK: Events from tiles and the collection view

        func click(_ id: String, modifiers: NSEvent.ModifierFlags) {
            guard let entry = entries[id] else { return }
            parent.onClick(entry, modifiers)
        }

        func menu(for id: String) -> NSMenu? {
            guard let entry = entries[id] else { return nil }
            let menu = NSMenu()
            for item in parent.menu(entry) {
                if item.isSeparator { menu.addItem(.separator()); continue }
                let mi = ClosureMenuItem(title: item.title, action: item.action)
                if let symbol = item.symbol { mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
                mi.isEnabled = item.enabled
                menu.addItem(mi)
            }
            menu.autoenablesItems = false
            return menu
        }

        func key(_ key: GridKey, _ modifiers: NSEvent.ModifierFlags) { parent.onKey(key, modifiers) }
        func magnify(_ amount: CGFloat) { parent.onMagnify(amount) }
        func backgroundClick() { parent.onBackgroundClick() }

        // MARK: Prefetching

        func collectionView(_ collectionView: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            ThumbnailPipeline.shared.prefetch(entries(at: indexPaths), pixels: currentPixels)
        }

        func collectionView(_ collectionView: NSCollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
            ThumbnailPipeline.shared.cancelPrefetch(entries(at: indexPaths), pixels: currentPixels)
        }

        private var currentPixels: Int {
            ThumbnailPipeline.bucket((layout?.side ?? 150) * (collectionView?.window?.backingScaleFactor ?? 2))
        }

        private func entries(at indexPaths: [IndexPath]) -> [GalleryEntry] {
            indexPaths.compactMap { dataSource?.itemIdentifier(for: $0) }.compactMap { entries[$0] }
        }

        // MARK: Drag to Finder (file promises: cloud items download while the drop completes)

        func beginDrag(from view: ThumbnailView, id: String, event: NSEvent) {
            guard let entry = entries[id] else { return }
            let group = parent.dragEntries(entry)
            let image = view.dragImage()
            var offset: CGFloat = 0
            let items: [NSDraggingItem] = group.prefix(50).map { e in
                let name = Self.filename(for: e)
                let type = UTType(filenameExtension: (name as NSString).pathExtension) ?? (e.isVideo ? .movie : .image)
                let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
                provider.userInfo = e
                let item = NSDraggingItem(pasteboardWriter: provider)
                item.setDraggingFrame(view.bounds.offsetBy(dx: offset, dy: -offset), contents: image)
                offset += 4
                return item
            }
            view.beginDraggingSession(with: items, event: event, source: self)
        }

        nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? .copy : []
        }

        nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
            guard let entry = provider.userInfo as? GalleryEntry else { return "Photo" }
            return Self.filename(for: entry)
        }

        nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
            guard let entry = provider.userInfo as? GalleryEntry else { completionHandler(nil); return }
            Task {
                do {
                    let file = try await GalleryActions.shareableFile(for: entry)
                    try? FileManager.default.removeItem(at: url)
                    try FileManager.default.moveItem(at: file, to: url)
                    try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
                    completionHandler(nil)
                } catch {
                    completionHandler(error)
                }
            }
        }

        nonisolated func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue {
            promiseQueue
        }

        nonisolated static func filename(for entry: GalleryEntry) -> String {
            if let asset = entry.asset {
                let resources = PHAssetResource.assetResources(for: asset)
                return (resources.first { $0.type == .fullSizePhoto || $0.type == .fullSizeVideo } ?? resources.first)?.originalFilename ?? "Photo"
            }
            return entry.item.map(CloudMediaService.displayedFilename) ?? "Photo"
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}

// MARK: - Layout

/// Square tiles filling the width exactly, sized from the zoom slider; date headers pinned while scrolling.
final class GridLayout: NSCollectionViewFlowLayout {
    static let spacing: CGFloat = 3
    static let gutter: CGFloat = 16

    var tileSize: CGFloat = 150 {
        didSet { if oldValue != tileSize { invalidateLayout() } }
    }
    var onColumns: ((Int) -> Void)?
    private(set) var side: CGFloat = 150
    private var columns = 0

    override init() {
        super.init()
        minimumInteritemSpacing = Self.spacing
        minimumLineSpacing = Self.spacing
        sectionHeadersPinToVisibleBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func prepare() {
        if let cv = collectionView {
            let width = max(cv.bounds.width - Self.gutter * 2, 100)
            let cols = max(1, Int((width + Self.spacing) / (tileSize + Self.spacing)))
            side = max(24, floor((width - Self.spacing * CGFloat(cols - 1)) / CGFloat(cols)))
            itemSize = NSSize(width: side, height: side)
            sectionInset = NSEdgeInsets(top: 0, left: Self.gutter, bottom: 14, right: Self.gutter)
            headerReferenceSize = NSSize(width: cv.bounds.width, height: 46)
            if cols != columns {
                columns = cols
                let report = onColumns
                DispatchQueue.main.async { report?(cols) }
            }
        }
        super.prepare()
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        if let cv = collectionView, cv.bounds.width != newBounds.width { return true }
        return super.shouldInvalidateLayout(forBoundsChange: newBounds)
    }
}

// MARK: - Collection view

/// Keyboard (arrows, Space / Return, Esc, Delete, ⌘A), trackpad pinch, and clicks on empty space.
final class GridCollectionView: NSCollectionView {
    weak var coordinator: MacPhotoGrid.Coordinator?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key: GridKey?
        switch event.keyCode {
        case 123: key = .left
        case 124: key = .right
        case 125: key = .down
        case 126: key = .up
        case 36, 76, 49: key = .open
        case 53: key = .escape
        case 51, 117: key = .delete
        default: key = mods.contains(.command) && event.charactersIgnoringModifiers == "a" ? .selectAll : nil
        }
        if let key, let coordinator { coordinator.key(key, mods) } else { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        coordinator?.backgroundClick()
    }

    override func magnify(with event: NSEvent) {
        coordinator?.magnify(event.magnification)
    }
}

// MARK: - Tile

final class ThumbnailItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("thumbnail")
    var thumbnail: ThumbnailView { view as! ThumbnailView }

    override func loadView() { view = ThumbnailView() }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnail.prepareForReuse()
    }
}

/// One tile drawn with layers: the image as layer contents (no SwiftUI, no per-frame work), a duration or
/// Live badge, the small backup badge, the selection ring and, in Select mode, the check circle.
final class ThumbnailView: NSView {
    weak var coordinator: MacPhotoGrid.Coordinator?

    private let imageLayer = CALayer()
    private let hoverLayer = CALayer()
    private let ringLayer = CALayer()
    private let duration = NSTextField(labelWithString: "")
    private let live = NSImageView()
    private let badge = BadgeNSView()
    private let check = NSImageView()

    private var entryId: String?
    private var loadedPixels = 0
    private var loadTask: Task<Void, Never>?
    private var tracking: NSTrackingArea?
    private var mouseDownEvent: NSEvent?
    private var dragging = false
    private var hasImage = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        layer?.masksToBounds = true
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        hoverLayer.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        hoverLayer.isHidden = true
        hoverLayer.actions = ["hidden": NSNull(), "bounds": NSNull(), "position": NSNull()]
        ringLayer.borderColor = NSColor.controlAccentColor.cgColor
        ringLayer.cornerRadius = 3
        ringLayer.actions = ["borderWidth": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(imageLayer)
        layer?.addSublayer(hoverLayer)

        duration.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        duration.textColor = .white
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = .zero
        duration.shadow = shadow
        live.image = NSImage(systemSymbolName: "livephoto", accessibilityDescription: "Live Photo")
        live.contentTintColor = .white
        live.shadow = shadow
        live.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        check.symbolConfiguration = .init(pointSize: 16, weight: .semibold)
        check.shadow = shadow
        for v in [duration, live, badge, check] as [NSView] { addSubview(v) }
        layer?.addSublayer(ringLayer)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        entryId = nil
        loadedPixels = 0
        hasImage = false
        imageLayer.contents = nil
        hoverLayer.isHidden = true
    }

    func configure(entry: GalleryEntry, side: CGFloat, pixels: Int, selecting: Bool, selected: Bool, cursor: Bool) {
        if entryId != entry.id {
            prepareForReuse()
            entryId = entry.id
            if let cached = ThumbnailPipeline.shared.cached(entry) {
                setImage(cached.image, animated: false)
                loadedPixels = cached.pixels
            }
        }
        if loadedPixels < pixels && loadTask == nil { load(entry, pixels: pixels) }

        if entry.isVideo, let d = entry.duration, side >= 56 {
            duration.stringValue = Duration.seconds(d).formatted(.time(pattern: .minuteSecond))
            duration.isHidden = false
        } else {
            duration.isHidden = true
        }
        live.isHidden = !(entry.isLive && !entry.isVideo && side >= 56)
        badge.configure(entry.badge, side: side)
        check.isHidden = !selecting || side < 44
        if selecting {
            check.image = NSImage(systemSymbolName: selected ? "checkmark.circle.fill" : "circle", accessibilityDescription: nil)
            check.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
                .applying(.init(paletteColors: selected ? [.white, .controlAccentColor] : [.white]))
        }
        ringLayer.borderWidth = selected ? 3 : (cursor ? 1.5 : 0)
        setAccessibilityLabel(entry.accessibilityLabel)
        setAccessibilitySelected(selected)
        needsLayout = true
    }

    private func load(_ entry: GalleryEntry, pixels: Int) {
        loadTask = Task { @MainActor [weak self] in
            for await image in ThumbnailPipeline.shared.images(for: entry, pixels: pixels) {
                guard let self, self.entryId == entry.id, !Task.isCancelled else { return }
                self.setImage(image, animated: !self.hasImage)
            }
            guard let self, self.entryId == entry.id else { return }
            self.loadedPixels = max(self.loadedPixels, pixels)
            self.loadTask = nil
        }
    }

    private func setImage(_ image: PlatformImage, animated: Bool) {
        if animated {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.15
            imageLayer.add(fade, forKey: "fade")
        }
        var rect = CGRect(origin: .zero, size: image.size)
        imageLayer.contents = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) ?? image
        hasImage = true
    }

    override func layout() {
        super.layout()
        let b = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = b
        hoverLayer.frame = b
        ringLayer.frame = b
        CATransaction.commit()
        duration.sizeToFit()
        duration.frame.origin = CGPoint(x: 5, y: b.height - duration.frame.height - 4)
        live.frame = CGRect(x: 5, y: b.height - 19, width: 15, height: 15)
        let s = badge.fittingSize
        let pad: CGFloat = b.width > 60 ? 4 : 2
        badge.frame = CGRect(x: b.width - s.width - pad, y: pad, width: s.width, height: s.height)
        check.frame = CGRect(x: b.width - 25, y: b.height - 25, width: 20, height: 20)
    }

    func dragImage() -> NSImage {
        let image = NSImage(size: bounds.size)
        if let contents = imageLayer.contents {
            image.lockFocus()
            if CFGetTypeID(contents as CFTypeRef) == CGImage.typeID, let ctx = NSGraphicsContext.current?.cgContext {
                let cg = contents as! CGImage
                let scale = max(bounds.width / CGFloat(cg.width), bounds.height / CGFloat(cg.height))
                let w = CGFloat(cg.width) * scale, h = CGFloat(cg.height) * scale
                ctx.draw(cg, in: CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h))
            }
            image.unlockFocus()
        }
        return image
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hoverLayer.isHidden = false }
    override func mouseExited(with event: NSEvent) { hoverLayer.isHidden = true }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        dragging = false
        if let cv = superview as? NSCollectionView ?? enclosingCollectionView { window?.makeFirstResponder(cv) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let down = mouseDownEvent, let id = entryId else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x, dy = event.locationInWindow.y - down.locationInWindow.y
        guard dx * dx + dy * dy > 16 else { return }
        dragging = true
        coordinator?.beginDrag(from: self, id: id, event: down)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        guard !dragging, let id = entryId else { return }
        coordinator?.click(id, modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let id = entryId else { return nil }
        return coordinator?.menu(for: id)
    }

    private var enclosingCollectionView: NSCollectionView? {
        var v = superview
        while let current = v, !(current is NSCollectionView) { v = current.superview }
        return v as? NSCollectionView
    }
}

/// The small backup status badge: a glyph on a dark disc, 7–10 pt depending on the tile size.
final class BadgeNSView: NSView {
    private let icon = NSImageView()
    private var symbol = ""
    private var pointSize: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        addSubview(icon)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ badge: BackupBadge, side: CGFloat) {
        let size = min(10, max(7, side * 0.065))
        guard badge.symbol != symbol || size != pointSize else { return }
        symbol = badge.symbol
        pointSize = size
        icon.image = NSImage(systemSymbolName: badge.symbol, accessibilityDescription: badge.label)
        icon.symbolConfiguration = .init(pointSize: size, weight: .bold)
        icon.contentTintColor = NSColor(badge.tint)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override var fittingSize: NSSize {
        let d = pointSize * 1.6 + 2
        return NSSize(width: d, height: d)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.width / 2
        icon.frame = bounds.insetBy(dx: pointSize * 0.28, dy: pointSize * 0.28)
    }
}

// MARK: - Section header

/// Date header like Photos: title, count, and Select / Deselect for the whole day (shown on hover or while selecting).
final class GridHeader: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("header")

    private let title = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let button = NSButton(title: "Select", target: nil, action: nil)
    private var onToggle: () -> Void = {}
    private var selecting = false
    private var hovering = false
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        count.textColor = .secondaryLabelColor
        count.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        button.bezelStyle = .inline
        button.isBordered = false
        button.contentTintColor = .controlAccentColor
        button.font = .systemFont(ofSize: 13, weight: .medium)
        button.target = self
        button.action = #selector(toggle)
        for v in [title, count, button] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(title text: String, count n: Int, large: Bool, selecting: Bool, allSelected: Bool, onToggle: @escaping () -> Void) {
        title.stringValue = text
        title.font = large ? .systemFont(ofSize: 20, weight: .bold) : .systemFont(ofSize: 15, weight: .semibold)
        count.stringValue = n.formatted()
        button.title = allSelected ? "Deselect" : "Select"
        self.selecting = selecting
        self.onToggle = onToggle
        button.isHidden = !(selecting || hovering)
        needsLayout = true
    }

    @objc private func toggle() { onToggle() }

    override func layout() {
        super.layout()
        title.sizeToFit()
        count.sizeToFit()
        button.sizeToFit()
        let baseline = bounds.height - 10
        title.frame.origin = CGPoint(x: GridLayout.gutter + 4, y: baseline - title.frame.height)
        count.frame.origin = CGPoint(x: title.frame.maxX + 8, y: title.frame.maxY - count.frame.height - (title.font?.pointSize ?? 15 > 16 ? 3 : 1))
        button.frame.origin = CGPoint(x: bounds.width - GridLayout.gutter - button.frame.width, y: baseline - button.frame.height)
    }

    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; button.isHidden = false }
    override func mouseExited(with event: NSEvent) { hovering = false; button.isHidden = !selecting }
}
