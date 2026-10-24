import SwiftUI
import UIKit
import CloudGalleryCore

/// The iPhone photo grid on UICollectionView, like Photos: recycled cells, thumbnails loaded ahead of the scroll,
/// pinch to change columns, Photos' own swipe-to-select, long-press to start selecting, and the viewer opening
/// with the system zoom transition from the tapped tile (iOS 18+). Everything around it stays SwiftUI.
struct NativePhotoGrid: UIViewRepresentable {
    let entries: [GalleryEntry]
    let sections: [GallerySection]
    /// Bumped whenever `sections` changes, so unrelated SwiftUI updates never touch the collection view.
    let dataVersion: Int
    @Binding var columns: Int
    let grouping: GalleryModel.Grouping
    let selecting: Bool
    @Binding var selection: Set<String>
    /// Scroll the grid so this section's header is at the top (date scrubber); applied when `scrubToken` changes.
    let scrubTarget: String?
    let scrubToken: Int
    let motion: GridMotion
    var onLongPress: (GalleryEntry) -> Void
    var onViewerPage: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UICollectionView {
        let c = context.coordinator
        let cv = UICollectionView(frame: .zero, collectionViewLayout: c.layout)
        cv.backgroundColor = .systemBackground
        cv.showsVerticalScrollIndicator = false
        cv.alwaysBounceVertical = true
        cv.allowsMultipleSelection = true
        cv.allowsMultipleSelectionDuringEditing = true
        cv.delegate = c
        cv.prefetchDataSource = c
        cv.accessibilityIdentifier = "galleryGrid"
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinched(_:)))
        cv.addGestureRecognizer(pinch)
        // Opening a photo is a tap that waits for the pinch to fail, so a pinch never opens the tile under a finger.
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tapped(_:)))
        tap.require(toFail: pinch)
        tap.cancelsTouchesInView = false
        cv.addGestureRecognizer(tap)
        let press = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.longPressed(_:)))
        press.minimumPressDuration = 0.4
        cv.addGestureRecognizer(press)
        c.attach(cv)
        return cv
    }

    func updateUIView(_ cv: UICollectionView, context: Context) {
        context.coordinator.update(self)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
        var parent: NativePhotoGrid
        private weak var collectionView: UICollectionView?
        private var dataSource: UICollectionViewDiffableDataSource<String, String>?
        private var entries: [String: GalleryEntry] = [:]
        private var sections: [String: GallerySection] = [:]
        private var appliedVersion = -1
        private var appliedColumns = 0
        private var appliedScrub = -1
        private var appliedSelecting = false
        private var appliedGrouping: GalleryModel.Grouping = .day
        private var viewerCurrentId: String?
        let layout: PinchGridLayout

        init(_ parent: NativePhotoGrid) {
            self.parent = parent
            appliedColumns = parent.columns
            appliedGrouping = parent.grouping
            layout = PinchGridLayout(columns: parent.columns)
        }

        // MARK: Setup

        func attach(_ cv: UICollectionView) {
            collectionView = cv
            let cell = UICollectionView.CellRegistration<PhotoCell, String> { [weak self] cell, _, id in
                guard let self, let entry = self.entries[id] else { return }
                self.configure(cell, entry)
            }
            let header = UICollectionView.SupplementaryRegistration<PhotoSectionHeader>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] view, _, ip in
                guard let self, let id = self.dataSource?.snapshot().sectionIdentifiers[safe: ip.section], let s = self.sections[id] else { return }
                view.configure(title: s.title, count: s.entries.count, large: self.parent.grouping != .day)
            }
            let ds = UICollectionViewDiffableDataSource<String, String>(collectionView: cv) { cv, ip, id in
                cv.dequeueConfiguredReusableCell(using: cell, for: ip, item: id)
            }
            ds.supplementaryViewProvider = { cv, _, ip in cv.dequeueConfiguredReusableSupplementary(using: header, for: ip) }
            dataSource = ds
            update(parent)
        }

        private func configure(_ cell: PhotoCell, _ entry: GalleryEntry) {
            let side = cell.bounds.width > 0 ? cell.bounds.width : (collectionView?.bounds.width ?? 390) / CGFloat(max(appliedColumns, 1))
            cell.configure(entry, side: side, pixels: ThumbnailPipeline.bucket(side * (collectionView?.traitCollection.displayScale ?? 3)),
                           selecting: parent.selecting, selected: parent.selection.contains(entry.id))
        }

        // MARK: Updates from SwiftUI

        func update(_ p: NativePhotoGrid) {
            parent = p
            // Mid-pinch (fingers down or settling) changes wait until it lands.
            guard let cv = collectionView, !pinchActive, settleLink == nil else { return }
            if p.columns != appliedColumns {
                // Columns picked from the menu: the tile at the top stays where it is.
                let keep = screenPosition(of: topVisibleItem(cv), in: cv)
                appliedColumns = p.columns
                layout.setColumns(p.columns)
                restore(keep, in: cv)
                refreshVisible()
            }
            if p.dataVersion != appliedVersion {
                // Regrouping (day ↔ month after a pinch) moves headers around; the tile at the top stays exactly where
                // it is on screen, which also holds while a finger is scrolling.
                let keep = p.grouping != appliedGrouping ? screenPosition(of: topVisibleItem(cv), in: cv) : nil
                appliedVersion = p.dataVersion
                apply(p.sections)
                restore(keep, in: cv)
                appliedGrouping = p.grouping
            }
            if p.selecting != appliedSelecting {
                appliedSelecting = p.selecting
                cv.isEditing = p.selecting
                refreshVisible()
            }
            syncSelection(cv)
            if p.scrubToken != appliedScrub {
                appliedScrub = p.scrubToken
                if let id = p.scrubTarget, let s = dataSource?.snapshot().indexOfSection(id) {
                    scrollToSection(s, in: cv)
                }
            }
        }

        private func apply(_ list: [GallerySection]) {
            var snapshot = NSDiffableDataSourceSnapshot<String, String>()
            var entries: [String: GalleryEntry] = [:]
            var sections: [String: GallerySection] = [:]
            snapshot.appendSections(list.map(\.id))
            for s in list {
                sections[s.id] = s
                snapshot.appendItems(s.entries.map(\.id), toSection: s.id)
                for e in s.entries { entries[e.id] = e }
            }
            self.entries = entries
            self.sections = sections
            dataSource?.apply(snapshot, animatingDifferences: false)
            // Same ids with new content (e.g. a backup finished): update visible tiles and headers in place.
            refreshVisible()
        }

        private func refreshVisible() {
            guard let cv = collectionView, let ds = dataSource else { return }
            for ip in cv.indexPathsForVisibleItems {
                guard let cell = cv.cellForItem(at: ip) as? PhotoCell, let id = ds.itemIdentifier(for: ip), let e = entries[id] else { continue }
                configure(cell, e)
            }
            let ids = ds.snapshot().sectionIdentifiers
            for ip in cv.indexPathsForVisibleSupplementaryElements(ofKind: UICollectionView.elementKindSectionHeader) {
                guard let header = cv.supplementaryView(forElementKind: UICollectionView.elementKindSectionHeader, at: ip) as? PhotoSectionHeader,
                      let id = ids[safe: ip.section], let s = sections[id] else { continue }
                header.configure(title: s.title, count: s.entries.count, large: parent.grouping != .day)
            }
        }

        /// SwiftUI owns the selection; mirror it into the collection view (selectItem doesn't call the delegate).
        private func syncSelection(_ cv: UICollectionView) {
            guard let ds = dataSource else { return }
            let current = Set((cv.indexPathsForSelectedItems ?? []).compactMap { ds.itemIdentifier(for: $0) })
            guard current != parent.selection else { return }
            for id in current.subtracting(parent.selection) { if let ip = ds.indexPath(for: id) { cv.deselectItem(at: ip, animated: false) } }
            for id in parent.selection.subtracting(current) { if let ip = ds.indexPath(for: id) { cv.selectItem(at: ip, animated: false, scrollPosition: []) } }
            refreshVisible()
        }

        private func topVisibleItem(_ cv: UICollectionView) -> IndexPath? {
            let top = cv.contentOffset.y + cv.adjustedContentInset.top + 50
            return cv.indexPathsForVisibleItems
                .filter { (cv.layoutAttributesForItem(at: $0)?.frame.maxY ?? 0) > top }
                .min { ($0.section, $0.item) < ($1.section, $1.item) }
        }

        /// An item (by id, so it survives regrouping) and how far below the top of the screen it is.
        private func screenPosition(of ip: IndexPath?, in cv: UICollectionView) -> (id: String, screenY: CGFloat)? {
            guard let ip, let id = dataSource?.itemIdentifier(for: ip), let f = layout.layoutAttributesForItem(at: ip)?.frame else { return nil }
            return (id, f.minY - cv.contentOffset.y)
        }

        /// Scrolls by however much the item moved, so it's back at the same place on screen.
        private func restore(_ keep: (id: String, screenY: CGFloat)?, in cv: UICollectionView) {
            guard let keep, let ip = dataSource?.indexPath(for: keep.id), let f = layout.layoutAttributesForItem(at: ip)?.frame else { return }
            setOffset(f.minY - keep.screenY, in: cv)
        }

        private func setOffset(_ y: CGFloat, in cv: UICollectionView) {
            let inset = cv.adjustedContentInset
            let maxY = max(-inset.top, layout.collectionViewContentSize.height - cv.bounds.height + inset.bottom)
            let clamped = min(maxY, max(-inset.top, y))
            if abs(clamped - cv.contentOffset.y) > 0.25 { cv.contentOffset.y = clamped }
        }

        private func scrollToSection(_ section: Int, in cv: UICollectionView) {
            guard let attrs = cv.layoutAttributesForSupplementaryElement(ofKind: UICollectionView.elementKindSectionHeader,
                                                                         at: IndexPath(item: 0, section: section)) else { return }
            let maxY = max(-cv.adjustedContentInset.top, cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom)
            cv.setContentOffset(CGPoint(x: 0, y: min(maxY, attrs.frame.minY - cv.adjustedContentInset.top)), animated: false)
        }

        // MARK: Taps and selection

        /// A pinch must never count as a tap on the tile under the fingers.
        private var pinchActive = false
        private var pinchEnded = Date.distantPast

        /// Selection is only used in Select mode (tap and swipe-to-select); outside it, taps open the viewer.
        func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
            parent.selecting && !pinchActive && Date().timeIntervalSince(pinchEnded) > 0.35
        }

        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard !parent.selecting, let cv = collectionView, let ip = cv.indexPathForItem(at: g.location(in: cv)),
                  let id = dataSource?.itemIdentifier(for: ip), let entry = entries[id] else { return }
            openViewer(entry, from: cv)
        }

        func collectionView(_ collectionView: UICollectionView, shouldDeselectItemAt indexPath: IndexPath) -> Bool {
            !pinchActive && Date().timeIntervalSince(pinchEnded) > 0.35
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard let id = dataSource?.itemIdentifier(for: indexPath), let entry = entries[id] else { return }
            _ = entry
            guard parent.selecting else { collectionView.deselectItem(at: indexPath, animated: false); return }
            parent.selection.insert(id)
            Haptics.tap()
            reconfigure(indexPath)
        }

        func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
            guard parent.selecting, let id = dataSource?.itemIdentifier(for: indexPath) else { return }
            parent.selection.remove(id)
            reconfigure(indexPath)
        }

        /// Photos' swipe-to-select: drag across tiles (one finger while selecting, or two fingers any time).
        func collectionView(_ collectionView: UICollectionView, shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool { parent.selecting }

        func collectionView(_ collectionView: UICollectionView, didBeginMultipleSelectionInteractionAt indexPath: IndexPath) {}

        private func reconfigure(_ ip: IndexPath) {
            guard let cell = collectionView?.cellForItem(at: ip) as? PhotoCell, let id = dataSource?.itemIdentifier(for: ip), let e = entries[id] else { return }
            configure(cell, e)
        }

        @objc func longPressed(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began, !parent.selecting, let cv = collectionView,
                  let ip = cv.indexPathForItem(at: g.location(in: cv)), let id = dataSource?.itemIdentifier(for: ip), let e = entries[id] else { return }
            parent.onLongPress(e)
        }

        // MARK: Pinch to change columns, like Photos

        /// The tiles follow the fingers: the layout blends between the current column count and the next one, the
        /// tile under the fingers stays under them (and follows them up and down), a long pinch steps through several
        /// sizes, and letting go settles in 0.2 s. Everything is synchronous, so scrolling works the moment it lands.
        private var pinchBase: CGFloat = 1
        private var pinchProgress: CGFloat = 0
        private var pinchTarget: Int?
        private var pinchAnchor: (indexPath: IndexPath, screenY: CGFloat)?
        private var fingerStartY: CGFloat = 0
        private var fingerY: CGFloat = 0
        private var settleLink: CADisplayLink?
        private var settleFrom: CGFloat = 0
        private var settleTo: CGFloat = 0
        private var settleStart: CFTimeInterval = 0

        @objc func pinched(_ g: UIPinchGestureRecognizer) {
            guard let cv = collectionView else { return }
            switch g.state {
            case .began:
                // A new pinch while the last one settles: land that one first.
                finishSettle()
                pinchActive = true
                pinchBase = g.scale
                pinchProgress = 0
                pinchTarget = nil
                // Two fingers would also pan the grid; the pinch moves it instead (the anchor follows the fingers).
                cv.panGestureRecognizer.isEnabled = false
                let point = g.location(in: cv)
                fingerStartY = point.y - cv.contentOffset.y
                fingerY = fingerStartY
                if let ip = cv.indexPathForItem(at: point) ?? topVisibleItem(cv), let frame = layout.layoutAttributesForItem(at: ip)?.frame {
                    pinchAnchor = (ip, frame.midY - cv.contentOffset.y)
                }
            case .changed:
                fingerY = g.location(in: cv).y - cv.contentOffset.y
                let relative = g.scale / pinchBase
                let zoomIn = relative > 1
                let target = zoomIn ? max(1, appliedColumns - 1) : min(10, appliedColumns + 1)
                // Zooming in needs a wider spread of the fingers than zooming out, as in Photos.
                let progress = min(1, max(0, zoomIn ? (relative - 1) / 0.6 : (1 - relative) / 0.3))
                if target == appliedColumns || progress == 0 {
                    pinchTarget = nil
                    pinchProgress = 0
                    layout.setColumns(appliedColumns)
                } else if progress >= 1 {
                    // Fully there with the fingers still moving: lock this step in and continue with the next one.
                    Haptics.tap()
                    commitColumns(target)
                    pinchBase = g.scale
                    pinchTarget = nil
                    pinchProgress = 0
                } else {
                    pinchTarget = target
                    pinchProgress = progress
                    layout.setTransition(to: target, progress: progress)
                }
                keepAnchor(cv)
            case .ended, .cancelled, .failed:
                pinchActive = false
                cv.panGestureRecognizer.isEnabled = true
                guard pinchTarget != nil, pinchProgress > 0 else {
                    pinchDone()
                    return
                }
                // Settle by distance and by the speed of the fingers at release.
                let zoomIn = (pinchTarget ?? appliedColumns) < appliedColumns
                let flick = zoomIn ? g.velocity > 1.5 : g.velocity < -1.5
                let finish = g.state == .ended && (pinchProgress > 0.35 || flick)
                if finish { Haptics.tap() }
                settleFrom = pinchProgress
                settleTo = finish ? 1 : 0
                settleStart = CACurrentMediaTime()
                let link = CADisplayLink(target: self, selector: #selector(settleTick(_:)))
                link.add(to: .main, forMode: .common)
                settleLink = link
            default: break
            }
        }

        /// Animates the remaining progress in 0.2 s (ease-out).
        @objc private func settleTick(_ link: CADisplayLink) {
            guard let cv = collectionView, let target = pinchTarget else { finishSettle(); return }
            let t = min(1, (CACurrentMediaTime() - settleStart) / 0.2)
            let eased = 1 - pow(1 - t, 3)
            pinchProgress = settleFrom + (settleTo - settleFrom) * eased
            guard t < 1 else { finishSettle(); return }
            layout.setTransition(to: target, progress: pinchProgress)
            keepAnchor(cv)
        }

        /// Lands the settle at its end right away (it ran out, a finger started scrolling, or a new pinch began).
        private func finishSettle() {
            guard let link = settleLink else { return }
            link.invalidate()
            settleLink = nil
            if let target = pinchTarget, settleTo >= 1 { commitColumns(target) } else { layout.setColumns(appliedColumns) }
            if let cv = collectionView, !cv.isDragging { keepAnchor(cv) }
            pinchDone()
        }

        private func commitColumns(_ c: Int) {
            appliedColumns = c
            layout.setColumns(c)
            parent.columns = c
        }

        /// The tile under the fingers stays under them while the tiles change size.
        private func keepAnchor(_ cv: UICollectionView) {
            guard let anchor = pinchAnchor, let frame = layout.layoutAttributesForItem(at: anchor.indexPath)?.frame else { return }
            setOffset(frame.midY - (anchor.screenY + fingerY - fingerStartY), in: cv)
        }

        private func pinchDone() {
            pinchTarget = nil
            pinchProgress = 0
            pinchEnded = Date()
            pinchAnchor = nil
            refreshVisible()
            update(parent)
        }

        // MARK: Scrolling (date scrubber)

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let range = scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.top + scrollView.adjustedContentInset.bottom
            parent.motion.fraction = range > 0 ? (scrollView.contentOffset.y + scrollView.adjustedContentInset.top) / range : 0
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            finishSettle()
            parent.motion.isScrolling = true
        }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { parent.motion.isScrolling = false } }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { parent.motion.isScrolling = false }

        // MARK: Prefetching

        func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            ThumbnailPipeline.shared.prefetch(entriesAt(indexPaths), pixels: pixels(collectionView))
        }

        func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
            ThumbnailPipeline.shared.cancelPrefetch(entriesAt(indexPaths), pixels: pixels(collectionView))
        }

        private func pixels(_ cv: UICollectionView) -> Int {
            ThumbnailPipeline.bucket(cv.bounds.width / CGFloat(max(appliedColumns, 1)) * cv.traitCollection.displayScale)
        }

        private func entriesAt(_ ips: [IndexPath]) -> [GalleryEntry] {
            ips.compactMap { dataSource?.itemIdentifier(for: $0) }.compactMap { entries[$0] }
        }

        // MARK: Viewer

        /// Presents the viewer with the system zoom from the tile (and back into the tile of the item on screen).
        private func openViewer(_ entry: GalleryEntry, from cv: UICollectionView) {
            guard let presenter = cv.window?.rootViewController?.topmostPresented else { return }
            viewerCurrentId = entry.id
            parent.onViewerPage(entry.id)
            var host: UIViewController?
            let viewer = ViewerView(entries: parent.entries, startId: entry.id, onPageChange: { [weak self] id in
                guard let self else { return }
                self.viewerCurrentId = id
                self.parent.onViewerPage(id)
                // Keep the grid under the viewer on the current item, so closing zooms into the right tile.
                if let cv = self.collectionView, let ip = self.dataSource?.indexPath(for: id) {
                    let frame = cv.layoutAttributesForItem(at: ip)?.frame ?? .zero
                    let visible = cv.bounds.inset(by: cv.adjustedContentInset)
                    if !visible.contains(frame) { cv.scrollToItem(at: ip, at: .centeredVertically, animated: false) }
                }
            }, onClose: { host?.dismiss(animated: true) })
            let controller = UIHostingController(rootView: viewer)
            host = controller
            controller.modalPresentationStyle = .fullScreen
            controller.view.backgroundColor = .black
            if #available(iOS 18.0, *) {
                controller.preferredTransition = .zoom { [weak self] _ in
                    guard let self, let cv = self.collectionView, let id = self.viewerCurrentId,
                          let ip = self.dataSource?.indexPath(for: id) else { return nil }
                    return cv.cellForItem(at: ip)
                }
            }
            presenter.present(controller, animated: true)
        }
    }
}

extension UIViewController {
    var topmostPresented: UIViewController {
        var top = self
        while let next = top.presentedViewController { top = next }
        return top
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - Cell

/// Tile: thumbnail, video duration or Live mark, the small backup badge, and the selection circle / ring.
final class PhotoCell: UICollectionViewCell {
    private let imageView = UIImageView()
    private let duration = UILabel()
    private let live = UIImageView(image: UIImage(systemName: "livephoto"))
    private let badge = UIImageView()
    private let badgeBackground = UIView()
    private let check = UIImageView()
    private let ring = UIView()
    private var entryId: String?
    private var loadedPixels = 0
    private var task: Task<Void, Never>?
    private var badgeSymbol = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemBackground
        contentView.clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        duration.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        duration.textColor = .white
        for v in [duration, live] as [UIView] {
            v.layer.shadowColor = UIColor.black.cgColor
            v.layer.shadowOpacity = 0.6
            v.layer.shadowRadius = 2
            v.layer.shadowOffset = .zero
        }
        live.tintColor = .white
        live.preferredSymbolConfiguration = .init(pointSize: 11, weight: .semibold)
        badgeBackground.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        check.preferredSymbolConfiguration = .init(pointSize: 20, weight: .regular)
        ring.layer.borderColor = UIColor.tintColor.cgColor
        ring.layer.borderWidth = 3
        ring.isUserInteractionEnabled = false
        for v in [imageView, duration, live, badgeBackground, badge, ring, check] as [UIView] { contentView.addSubview(v) }
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func prepareForReuse() {
        super.prepareForReuse()
        task?.cancel()
        task = nil
        entryId = nil
        loadedPixels = 0
        imageView.image = nil
    }

    func configure(_ entry: GalleryEntry, side: CGFloat, pixels: Int, selecting: Bool, selected: Bool) {
        if entryId != entry.id {
            task?.cancel()
            task = nil
            entryId = entry.id
            loadedPixels = 0
            imageView.image = nil
            if let cached = ThumbnailPipeline.shared.cached(entry) {
                imageView.image = cached.image
                loadedPixels = cached.pixels
            }
        }
        if loadedPixels < pixels && task == nil {
            task = Task { [weak self] in
                for await img in ThumbnailPipeline.shared.images(for: entry, pixels: pixels) {
                    guard let self, self.entryId == entry.id else { return }
                    let first = self.imageView.image == nil
                    self.imageView.image = img
                    if first {
                        self.imageView.alpha = 0
                        UIView.animate(withDuration: 0.15) { self.imageView.alpha = 1 }
                    }
                }
                guard let self, self.entryId == entry.id else { return }
                self.loadedPixels = max(self.loadedPixels, pixels)
                self.task = nil
            }
        }

        if entry.isVideo, let d = entry.duration {
            duration.text = Duration.seconds(d).formatted(.time(pattern: .minuteSecond))
            duration.isHidden = side < 40
            live.isHidden = true
        } else {
            duration.isHidden = true
            live.isHidden = !entry.isLive || side < 40
        }

        let size = min(10, max(7, side * 0.065))
        if badgeSymbol != entry.badge.symbol + "\(size)" {
            badgeSymbol = entry.badge.symbol + "\(size)"
            badge.image = UIImage(systemName: entry.badge.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .bold))
        }
        badge.tintColor = UIColor(entry.badge.tint)
        if entry.badge == .uploading {
            if badge.layer.animation(forKey: "spin") == nil {
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.toValue = Double.pi * 2
                spin.duration = 1.2
                spin.repeatCount = .infinity
                badge.layer.add(spin, forKey: "spin")
            }
        } else {
            badge.layer.removeAnimation(forKey: "spin")
        }

        check.isHidden = !selecting || side < 34
        check.image = UIImage(systemName: selected ? "checkmark.circle.fill" : "circle")
        check.tintColor = selected ? .tintColor : .white
        check.backgroundColor = selected ? .white : UIColor.black.withAlphaComponent(0.2)
        ring.isHidden = !selected
        accessibilityLabel = entry.accessibilityLabel
        accessibilityTraits = selected ? [.button, .selected] : .button
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let b = contentView.bounds
        imageView.frame = b
        ring.frame = b
        duration.sizeToFit()
        duration.frame.origin = CGPoint(x: 4, y: b.height - duration.frame.height - 3)
        live.sizeToFit()
        live.frame.origin = CGPoint(x: 4, y: b.height - live.frame.height - 4)
        let s = badge.image?.size ?? .zero
        let d = max(s.width, s.height) + 4
        let pad: CGFloat = b.width > 60 ? 4 : 2
        badgeBackground.frame = CGRect(x: b.width - d - pad, y: pad, width: d, height: d)
        badgeBackground.layer.cornerRadius = d / 2
        badge.bounds = CGRect(origin: .zero, size: s)
        badge.center = CGPoint(x: badgeBackground.frame.midX, y: badgeBackground.frame.midY)
        let c = check.intrinsicContentSize
        check.frame = CGRect(x: b.width - c.width - 5, y: b.height - c.height - 5, width: c.width, height: c.height)
        check.layer.cornerRadius = c.width / 2
    }
}

/// Date header like Photos: bold day / month / year title with the item count.
final class PhotoSectionHeader: UICollectionReusableView {
    private let title = UILabel()
    private let count = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        count.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        count.textColor = .secondaryLabel
        addSubview(title)
        addSubview(count)
        isAccessibilityElement = true
        accessibilityTraits = .header
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(title text: String, count n: Int, large: Bool) {
        title.text = text
        title.font = large ? UIFont.systemFont(ofSize: 20, weight: .bold) : .preferredFont(forTextStyle: .headline)
        count.text = n.formatted()
        accessibilityLabel = "\(text), \(n) items"
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        title.sizeToFit()
        count.sizeToFit()
        title.frame.origin = CGPoint(x: 14, y: bounds.height - title.frame.height - 8)
        count.frame.origin = CGPoint(x: bounds.width - count.frame.width - 14, y: title.frame.maxY - count.frame.height - 1)
    }
}

// MARK: - Layout

/// Square tiles in rows under date headers, plus the in-between state shown while pinching: every tile and header
/// sits part way between its place at the current column count and at the next one. Positions are arithmetic, so a
/// pinch frame only touches what's on screen, and nothing waits on UIKit's own layout transitions.
final class PinchGridLayout: UICollectionViewLayout {
    static let headerHeight: CGFloat = 48
    private let spacing: CGFloat = 2
    private(set) var columns: Int
    /// Column count being moved toward, and how far (0…1).
    private(set) var target: Int?
    private(set) var progress: CGFloat = 0

    private struct Metrics {
        let columns: Int
        let side: CGFloat
        let pitchX: CGFloat
        let tops: [CGFloat]
        let height: CGFloat
    }

    private var counts: [Int] = []
    private var width: CGFloat = 0
    private var countsValid = false
    private var cache: [Int: Metrics] = [:]

    init(columns: Int) {
        self.columns = max(1, columns)
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setColumns(_ c: Int) {
        columns = max(1, c)
        target = nil
        progress = 0
        invalidateLayout(with: UICollectionViewLayoutInvalidationContext())
    }

    func setTransition(to t: Int, progress p: CGFloat) {
        target = t
        progress = min(1, max(0, p))
        invalidateLayout(with: UICollectionViewLayoutInvalidationContext())
    }

    override func invalidateLayout(with context: UICollectionViewLayoutInvalidationContext) {
        if context.invalidateEverything || context.invalidateDataSourceCounts { countsValid = false }
        super.invalidateLayout(with: context)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { newBounds.width != width }

    override func prepare() {
        super.prepare()
        refreshIfNeeded()
    }

    private func refreshIfNeeded() {
        guard let cv = collectionView else { return }
        let w = cv.bounds.width
        guard !countsValid || w != width else { return }
        counts = (0..<cv.numberOfSections).map { cv.numberOfItems(inSection: $0) }
        width = w
        countsValid = true
        cache = [:]
    }

    private func metrics(_ c: Int) -> Metrics {
        refreshIfNeeded()
        if let m = cache[c] { return m }
        let side = max(1, floor((width - spacing * CGFloat(c - 1)) / CGFloat(c)))
        let pitchX = c > 1 ? side + (width - side * CGFloat(c)) / CGFloat(c - 1) : 0
        var tops: [CGFloat] = []
        tops.reserveCapacity(counts.count)
        var y: CGFloat = 0
        for n in counts {
            tops.append(y)
            let rows = (n + c - 1) / c
            y += Self.headerHeight + (rows > 0 ? CGFloat(rows) * side + CGFloat(rows - 1) * spacing : 0)
        }
        let m = Metrics(columns: c, side: side, pitchX: pitchX, tops: tops, height: y)
        cache[c] = m
        return m
    }

    /// The two states being blended (the same one twice when not pinching).
    private var states: (Metrics, Metrics, CGFloat) {
        let a = metrics(columns)
        guard let target, progress > 0 else { return (a, a, 0) }
        return (a, metrics(target), progress)
    }

    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    private func itemFrame(_ i: Int, _ s: Int, _ m: Metrics) -> CGRect {
        let row = i / m.columns, col = i % m.columns
        return CGRect(x: CGFloat(col) * m.pitchX, y: m.tops[s] + Self.headerHeight + CGFloat(row) * (m.side + spacing),
                      width: m.side, height: m.side)
    }

    private func itemFrame(_ i: Int, _ s: Int) -> CGRect {
        let (a, b, t) = states
        let fa = itemFrame(i, s, a)
        guard t > 0 else { return fa }
        let fb = itemFrame(i, s, b)
        let side = Self.lerp(fa.width, fb.width, t)
        return CGRect(x: Self.lerp(fa.minX, fb.minX, t), y: Self.lerp(fa.minY, fb.minY, t), width: side, height: side)
    }

    private func headerFrame(_ s: Int) -> CGRect {
        let (a, b, t) = states
        return CGRect(x: 0, y: Self.lerp(a.tops[s], b.tops[s], t), width: width, height: Self.headerHeight)
    }

    override var collectionViewContentSize: CGSize {
        let (a, b, t) = states
        return CGSize(width: width, height: Self.lerp(a.height, b.height, t))
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        let (a, b, t) = states
        guard !counts.isEmpty else { return [] }
        let top = { (s: Int) in Self.lerp(a.tops[s], b.tops[s], t) }
        let side = Self.lerp(a.side, b.side, t)
        // Last section starting at or above the rect (tops only grow, in both states and so in the blend).
        var lo = 0, hi = counts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if top(mid) <= rect.minY { lo = mid } else { hi = mid - 1 }
        }
        var out: [UICollectionViewLayoutAttributes] = []
        for s in lo..<counts.count {
            let sectionTop = top(s)
            if sectionTop > rect.maxY { break }
            let header = CGRect(x: 0, y: sectionTop, width: width, height: Self.headerHeight)
            if header.intersects(rect) { out.append(headerAttributes(s, header)) }
            let n = counts[s]
            guard n > 0 else { continue }
            let minY = { (i: Int) in Self.lerp(self.itemFrame(i, s, a).minY, self.itemFrame(i, s, b).minY, t) }
            // First tile whose bottom reaches the rect, then every tile until one starts below it.
            var first = 0, last = n
            while first < last {
                let mid = (first + last) / 2
                if minY(mid) + side < rect.minY { first = mid + 1 } else { last = mid }
            }
            var i = first
            while i < n {
                let f = itemFrame(i, s)
                if f.minY > rect.maxY { break }
                if f.intersects(rect) {
                    let attrs = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: i, section: s))
                    attrs.frame = f
                    out.append(attrs)
                }
                i += 1
            }
        }
        return out
    }

    private func headerAttributes(_ s: Int, _ frame: CGRect) -> UICollectionViewLayoutAttributes {
        let attrs = UICollectionViewLayoutAttributes(forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                                                     with: IndexPath(item: 0, section: s))
        attrs.frame = frame
        attrs.zIndex = 1
        return attrs
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        refreshIfNeeded()
        guard indexPath.section < counts.count, indexPath.item < counts[indexPath.section] else { return nil }
        let attrs = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attrs.frame = itemFrame(indexPath.item, indexPath.section)
        return attrs
    }

    override func layoutAttributesForSupplementaryView(ofKind elementKind: String, at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        refreshIfNeeded()
        guard elementKind == UICollectionView.elementKindSectionHeader, indexPath.section < counts.count else { return nil }
        return headerAttributes(indexPath.section, headerFrame(indexPath.section))
    }
}
