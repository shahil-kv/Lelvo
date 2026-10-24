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
        let cv = UICollectionView(frame: .zero, collectionViewLayout: c.makeLayout())
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
        private let spacing: CGFloat = 2

        init(_ parent: NativePhotoGrid) {
            self.parent = parent
            appliedColumns = parent.columns
            appliedGrouping = parent.grouping
        }

        // MARK: Setup

        func makeLayout() -> UICollectionViewCompositionalLayout {
            let columns = max(1, appliedColumns)
            let spacing = self.spacing
            return UICollectionViewCompositionalLayout { _, env in
                let width = env.container.effectiveContentSize.width
                let side = floor((width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
                let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .absolute(side), heightDimension: .absolute(side)))
                let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(side)),
                                                               repeatingSubitem: item, count: columns)
                group.interItemSpacing = .flexible(spacing)
                let section = NSCollectionLayoutSection(group: group)
                section.interGroupSpacing = spacing
                let header = NSCollectionLayoutBoundarySupplementaryItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(48)),
                                                                         elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
                section.boundarySupplementaryItems = [header]
                return section
            }
        }

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
            guard let cv = collectionView else { return }
            if p.columns != appliedColumns {
                // Keep the item at the top in place while the columns change (pinch), like Photos.
                let anchor = topVisibleItem(cv)
                appliedColumns = p.columns
                cv.setCollectionViewLayout(makeLayout(), animated: false)
                if p.dataVersion == appliedVersion, let anchor { scroll(toAnchor: anchor, in: cv) }
                refreshVisible()
            }
            if p.dataVersion != appliedVersion {
                let anchorId = topVisibleItem(cv).flatMap { dataSource?.itemIdentifier(for: $0) }
                appliedVersion = p.dataVersion
                apply(p.sections)
                if p.grouping != appliedGrouping, let anchorId, let ip = dataSource?.indexPath(for: anchorId) {
                    cv.layoutIfNeeded()
                    scroll(toAnchor: ip, in: cv)
                }
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

        /// Puts the anchor item at the top; when it's in its section's first row, the date header stays visible above it.
        private func scroll(toAnchor ip: IndexPath, in cv: UICollectionView) {
            guard ip.section < cv.numberOfSections, ip.item < cv.numberOfItems(inSection: ip.section) else { return }
            if ip.item < appliedColumns {
                scrollToSection(ip.section, in: cv)
            } else {
                cv.scrollToItem(at: ip, at: .top, animated: false)
            }
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

        // MARK: Pinch to change columns (with live feedback, like Photos)

        @objc func pinched(_ g: UIPinchGestureRecognizer) {
            guard let cv = collectionView else { return }
            if g.state == .began || g.state == .changed { pinchActive = true }
            if g.state == .ended || g.state == .cancelled || g.state == .failed { pinchActive = false; pinchEnded = Date() }
            switch g.state {
            case .changed:
                // Live feedback: scale around the top edge of what's on screen.
                let s = min(1.2, max(0.8, g.scale))
                cv.transform = CGAffineTransform(scaleX: s, y: s)
                    .concatenating(CGAffineTransform(translationX: 0, y: -(1 - s) * cv.bounds.height / 2))
            case .ended, .cancelled, .failed:
                let scale = g.scale
                var c = parent.columns
                if scale > 1.15 { c = max(1, c - (scale > 1.6 ? 2 : 1)) } else if scale < 0.85 { c = min(10, c + (scale < 0.6 ? 2 : 1)) }
                let anchor = topVisibleItem(cv)
                if c != parent.columns {
                    Haptics.tap()
                    appliedColumns = c
                    parent.columns = c
                    cv.transform = .identity
                    // Animated relayout: tiles glide to their new size and place, like Photos.
                    cv.setCollectionViewLayout(makeLayout(), animated: true) { _ in
                        if let anchor { self.scroll(toAnchor: anchor, in: cv) }
                        self.refreshVisible()
                    }
                } else {
                    UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0) { cv.transform = .identity }
                }
            default: break
            }
        }

        // MARK: Scrolling (date scrubber)

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let range = scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.top + scrollView.adjustedContentInset.bottom
            parent.motion.fraction = range > 0 ? (scrollView.contentOffset.y + scrollView.adjustedContentInset.top) / range : 0
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { parent.motion.isScrolling = true }
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
