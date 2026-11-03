import SwiftUI
import UIKit
import LelvoCore

/// The tiles of Recently Deleted, with swipe-to-select as in Photos: in Select mode a sideways swipe selects everything
/// between, and holding near the top or bottom edge keeps scrolling. An up-and-down swipe scrolls. A short list, so unlike
/// `NativePhotoGrid` each tile can be a SwiftUI view.
struct TrashGrid: UIViewRepresentable {
    let items: [MediaItem]
    let selecting: Bool
    @Binding var selection: Set<String>
    let tapped: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewCompositionalLayout { _, environment in
            let width = environment.container.effectiveContentSize.width
            let columns = max(3, Int((width + 2) / 106))
            let side = NSCollectionLayoutDimension.fractionalWidth(1 / CGFloat(columns))
            let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(widthDimension: side, heightDimension: side))
            item.contentInsets = NSDirectionalEdgeInsets(top: 1, leading: 1, bottom: 1, trailing: 1)
            let row = NSCollectionLayoutGroup.horizontal(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: side),
                                                         subitems: [item])
            return NSCollectionLayoutSection(group: row)
        }
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.accessibilityIdentifier = "trashGrid"
        cv.backgroundColor = .clear
        cv.alwaysBounceVertical = true
        cv.delegate = context.coordinator
        context.coordinator.attach(to: cv)
        // The grid scrolls only once a swipe across the tiles has been ruled out.
        let swipe = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swiped(_:)))
        swipe.maximumNumberOfTouches = 1
        swipe.delegate = context.coordinator
        cv.addGestureRecognizer(swipe)
        cv.panGestureRecognizer.require(toFail: swipe)
        return cv
    }

    func updateUIView(_ uiView: UICollectionView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleUIView(_ uiView: UICollectionView, coordinator: Coordinator) {
        coordinator.endSwipe(publish: false)
    }

    final class Coordinator: NSObject, UICollectionViewDelegate, UIGestureRecognizerDelegate {
        private var parent: TrashGrid
        private weak var collectionView: UICollectionView?
        private var dataSource: UICollectionViewDiffableDataSource<Int, String>?
        private var byId: [String: MediaItem] = [:]
        private var shownSelecting = false
        private var shownSelection = Set<String>()

        private var swipe: SwipeSelection?
        private weak var swipePan: UIPanGestureRecognizer?
        private var swipeLink: CADisplayLink?
        private var swipeLastTick: CFTimeInterval = 0
        private var swipePublished: CFTimeInterval = 0
        private var swipeUnpublished = false
        private var swipeStartY: CGFloat = 0
        private var swipeCanScroll = false

        init(_ parent: TrashGrid) {
            self.parent = parent
        }

        func attach(to cv: UICollectionView) {
            collectionView = cv
            let cell = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, id in
                guard let self, let item = byId[id] else { return }
                let selected = (swipe?.selection ?? parent.selection).contains(id)
                cell.contentConfiguration = UIHostingConfiguration {
                    TrashTile(item: item, selecting: self.parent.selecting, isSelected: selected)
                }
                .margins(.all, 0)
            }
            dataSource = UICollectionViewDiffableDataSource(collectionView: cv) { cv, indexPath, id in
                cv.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: id)
            }
        }

        func update(_ next: TrashGrid) {
            parent = next
            // Select mode ended under the finger (Done, or an action finished): the swipe must not bring the selection back.
            if swipe != nil, !next.selecting { endSwipe(publish: false); return }
            guard swipe == nil, let dataSource else { return }
            byId = Dictionary(next.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var snapshot = dataSource.snapshot()
            let ids = next.items.map(\.id)
            if snapshot.itemIdentifiers != ids {
                snapshot = NSDiffableDataSourceSnapshot()
                snapshot.appendSections([0])
                snapshot.appendItems(ids)
            }
            // Only the tiles that changed: a whole reload would restart every thumbnail.
            let changed = next.selecting != shownSelecting ? Set(ids) : next.selection.symmetricDifference(shownSelection).intersection(ids)
            snapshot.reconfigureItems(Array(changed.intersection(snapshot.itemIdentifiers)))
            shownSelecting = next.selecting
            shownSelection = next.selection
            dataSource.apply(snapshot, animatingDifferences: false)
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            // The selection lives in SwiftUI, as the tiles draw it.
            collectionView.deselectItem(at: indexPath, animated: false)
            guard let id = dataSource?.itemIdentifier(for: indexPath) else { return }
            Haptics.selection()
            parent.tapped(id)
        }

        // MARK: Swipe to select

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer, let cv = collectionView, parent.selecting else { return false }
            let v = pan.velocity(in: cv)
            guard abs(v.x) > abs(v.y) else { return false }
            return cv.indexPathForItem(at: swipeStart(pan, in: cv)) != nil
        }

        /// Where the finger came down: the recogniser only starts after it has moved a little.
        private func swipeStart(_ pan: UIPanGestureRecognizer, in cv: UICollectionView) -> CGPoint {
            let p = pan.location(in: cv), t = pan.translation(in: cv)
            return CGPoint(x: p.x - t.x, y: p.y - t.y)
        }

        @objc func swiped(_ g: UIPanGestureRecognizer) {
            guard let cv = collectionView else { return }
            switch g.state {
            case .began:
                beginSwipe(g, in: cv)
            case .ended:
                moveSwipe(to: g.location(in: cv), in: cv)
                endSwipe(publish: true)
            case .cancelled, .failed:
                endSwipe(publish: true)
            default:
                break // The display link follows the finger, also while it rests and the grid scrolls under it.
            }
        }

        private func beginSwipe(_ g: UIPanGestureRecognizer, in cv: UICollectionView) {
            guard let dataSource, let ip = cv.indexPathForItem(at: swipeStart(g, in: cv)) else { return }
            swipe = SwipeSelection(order: dataSource.snapshot().itemIdentifiers, anchor: ip.item, selection: parent.selection)
            swipePan = g
            swipeStartY = g.location(in: cv).y - cv.contentOffset.y
            swipeCanScroll = false
            swipeUnpublished = true
            swipePublished = 0
            swipeLastTick = CACurrentMediaTime()
            reconfigure([ip])
            moveSwipe(to: g.location(in: cv), in: cv)
            Haptics.selection()
            let link = CADisplayLink(target: self, selector: #selector(swipeTick(_:)))
            link.add(to: .main, forMode: .common)
            swipeLink = link
        }

        @objc private func swipeTick(_ link: CADisplayLink) {
            guard let cv = collectionView, let pan = swipePan, swipe != nil else { return }
            let now = CACurrentMediaTime()
            let dt = min(1.0 / 30, now - swipeLastTick)
            swipeLastTick = now
            let fingerY = pan.location(in: cv).y - cv.contentOffset.y
            // Starting near an edge must not scroll until the finger has really moved up or down.
            if abs(fingerY - swipeStartY) > 24 { swipeCanScroll = true }
            if swipeCanScroll {
                let speed = SwipeSelection.autoScrollSpeed(fingerY: fingerY, top: cv.adjustedContentInset.top,
                                                           bottom: cv.bounds.height - cv.adjustedContentInset.bottom)
                if speed != 0 {
                    let top = -cv.adjustedContentInset.top
                    let bottom = max(top, cv.contentSize.height + cv.adjustedContentInset.bottom - cv.bounds.height)
                    cv.contentOffset.y = min(bottom, max(top, cv.contentOffset.y + speed * dt))
                }
            }
            moveSwipe(to: pan.location(in: cv), in: cv)
            if swipeUnpublished, now - swipePublished >= 0.1, let swipe {
                swipeUnpublished = false
                swipePublished = now
                parent.selection = swipe.selection
            }
        }

        private func moveSwipe(to point: CGPoint, in cv: UICollectionView) {
            // Off the sides or over the bars still means the nearest tile on screen.
            let visible = cv.bounds.inset(by: cv.adjustedContentInset)
            let p = CGPoint(x: min(visible.maxX - 1, max(visible.minX + 1, point.x)), y: min(visible.maxY - 1, max(visible.minY + 1, point.y)))
            // The gap at the end of the last row: stay on the last tile.
            guard let ip = cv.indexPathForItem(at: p), let changed = swipe?.move(to: ip.item), !changed.isEmpty, let dataSource else { return }
            swipeUnpublished = true
            let ids = Set(changed)
            reconfigure(cv.indexPathsForVisibleItems.filter { dataSource.itemIdentifier(for: $0).map(ids.contains) ?? false })
        }

        private func reconfigure(_ indexPaths: [IndexPath]) {
            guard let dataSource, !indexPaths.isEmpty else { return }
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems(indexPaths.compactMap { dataSource.itemIdentifier(for: $0) })
            dataSource.apply(snapshot, animatingDifferences: false)
        }

        func endSwipe(publish: Bool) {
            guard let finished = swipe else { return }
            swipeLink?.invalidate()
            swipeLink = nil
            swipe = nil
            if publish { parent.selection = finished.selection }
            update(parent)
        }
    }
}
