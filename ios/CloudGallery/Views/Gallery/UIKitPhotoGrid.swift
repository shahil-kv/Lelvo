import SwiftUI
import UIKit
import CloudGalleryCore

/// The iPhone grid on UICollectionView (recycled cells, prefetching, pinned date headers): the candidate
/// replacement for the SwiftUI LazyVGrid, measured against it with `ScrollBenchmark`.
struct UIKitPhotoGrid: UIViewRepresentable {
    let sections: [GallerySection]
    let dataVersion: Int
    let columns: Int
    var onTap: (GalleryEntry) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UICollectionView {
        let cv = UICollectionView(frame: .zero, collectionViewLayout: Self.layout(columns: columns))
        cv.backgroundColor = .systemBackground
        cv.prefetchDataSource = context.coordinator
        cv.delegate = context.coordinator
        cv.showsVerticalScrollIndicator = false
        context.coordinator.attach(cv)
        return cv
    }

    func updateUIView(_ cv: UICollectionView, context: Context) {
        let c = context.coordinator
        c.onTap = onTap
        if c.columns != columns {
            c.columns = columns
            cv.setCollectionViewLayout(Self.layout(columns: columns), animated: false)
        }
        if c.version != dataVersion {
            c.version = dataVersion
            c.apply(sections)
        }
    }

    static func layout(columns: Int) -> UICollectionViewCompositionalLayout {
        let spacing: CGFloat = 2
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1 / CGFloat(columns)), heightDimension: .fractionalWidth(1 / CGFloat(columns))))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalWidth(1 / CGFloat(columns))),
                                                       repeatingSubitem: item, count: columns)
        group.interItemSpacing = .fixed(spacing)
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = spacing
        let header = NSCollectionLayoutBoundarySupplementaryItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(44)),
                                                                 elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
        header.pinToVisibleBounds = true
        section.boundarySupplementaryItems = [header]
        return UICollectionViewCompositionalLayout(section: section)
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
        var version = -1
        var columns = 0
        var onTap: (GalleryEntry) -> Void = { _ in }
        private var dataSource: UICollectionViewDiffableDataSource<String, String>?
        private var entries: [String: GalleryEntry] = [:]
        private var sections: [String: GallerySection] = [:]
        private weak var collectionView: UICollectionView?

        func attach(_ cv: UICollectionView) {
            collectionView = cv
            let cell = UICollectionView.CellRegistration<GridCell, String> { [weak self] cell, _, id in
                guard let self, let entry = self.entries[id] else { return }
                cell.configure(entry, pixels: ThumbnailPipeline.bucket(cell.bounds.width * cell.traitCollection.displayScale))
            }
            let header = UICollectionView.SupplementaryRegistration<GridHeaderView>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] view, _, ip in
                guard let self, let id = self.dataSource?.snapshot().sectionIdentifiers[ip.section], let s = self.sections[id] else { return }
                view.configure(title: s.title, count: s.entries.count)
            }
            let ds = UICollectionViewDiffableDataSource<String, String>(collectionView: cv) { cv, ip, id in
                cv.dequeueConfiguredReusableCell(using: cell, for: ip, item: id)
            }
            ds.supplementaryViewProvider = { cv, _, ip in cv.dequeueConfiguredReusableSupplementary(using: header, for: ip) }
            dataSource = ds
        }

        func apply(_ list: [GallerySection]) {
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
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            if let id = dataSource?.itemIdentifier(for: indexPath), let e = entries[id] { onTap(e) }
        }

        func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            ThumbnailPipeline.shared.prefetch(entriesAt(indexPaths), pixels: pixels(collectionView))
        }

        func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
            ThumbnailPipeline.shared.cancelPrefetch(entriesAt(indexPaths), pixels: pixels(collectionView))
        }

        private func pixels(_ cv: UICollectionView) -> Int {
            ThumbnailPipeline.bucket(cv.bounds.width / CGFloat(max(columns, 1)) * cv.traitCollection.displayScale)
        }

        private func entriesAt(_ ips: [IndexPath]) -> [GalleryEntry] {
            ips.compactMap { dataSource?.itemIdentifier(for: $0) }.compactMap { entries[$0] }
        }
    }
}

/// Tile: image, duration / Live mark, the small backup badge.
final class GridCell: UICollectionViewCell {
    private let imageView = UIImageView()
    private let duration = UILabel()
    private let badge = UIImageView()
    private let badgeBackground = UIView()
    private var entryId: String?
    private var task: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemBackground
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        duration.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        duration.textColor = .white
        duration.layer.shadowColor = UIColor.black.cgColor
        duration.layer.shadowOpacity = 0.6
        duration.layer.shadowRadius = 2
        duration.layer.shadowOffset = .zero
        badgeBackground.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        for v in [imageView, duration, badgeBackground, badge] { contentView.addSubview(v) }
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func prepareForReuse() {
        super.prepareForReuse()
        task?.cancel()
        task = nil
        entryId = nil
        imageView.image = nil
    }

    func configure(_ entry: GalleryEntry, pixels: Int) {
        entryId = entry.id
        if let cached = ThumbnailPipeline.shared.cached(entry) {
            imageView.image = cached.image
            if cached.pixels >= pixels { return finish(entry) }
        }
        task = Task { [weak self] in
            for await img in ThumbnailPipeline.shared.images(for: entry, pixels: pixels) {
                guard let self, self.entryId == entry.id else { return }
                self.imageView.image = img
            }
        }
        finish(entry)
    }

    private func finish(_ entry: GalleryEntry) {
        if entry.isVideo, let d = entry.duration {
            duration.text = Duration.seconds(d).formatted(.time(pattern: .minuteSecond))
            duration.isHidden = false
        } else {
            duration.isHidden = true
        }
        let side = bounds.width
        let size = min(10, max(7, side * 0.065))
        badge.image = UIImage(systemName: entry.badge.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .bold))
        badge.tintColor = UIColor(entry.badge.tint)
        accessibilityLabel = entry.accessibilityLabel
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let b = contentView.bounds
        imageView.frame = b
        duration.sizeToFit()
        duration.frame.origin = CGPoint(x: 4, y: b.height - duration.frame.height - 3)
        let s = badge.image?.size ?? .zero
        let d = max(s.width, s.height) + 4
        let pad: CGFloat = b.width > 60 ? 4 : 2
        badgeBackground.frame = CGRect(x: b.width - d - pad, y: pad, width: d, height: d)
        badgeBackground.layer.cornerRadius = d / 2
        badge.frame = CGRect(x: badgeBackground.frame.midX - s.width / 2, y: badgeBackground.frame.midY - s.height / 2, width: s.width, height: s.height)
    }
}

final class GridHeaderView: UICollectionReusableView {
    private let title = UILabel()
    private let count = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        title.font = .preferredFont(forTextStyle: .headline)
        count.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        count.textColor = .secondaryLabel
        addSubview(title)
        addSubview(count)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(title text: String, count n: Int) {
        title.text = text
        count.text = n.formatted()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        title.sizeToFit()
        count.sizeToFit()
        title.frame.origin = CGPoint(x: 14, y: bounds.height - title.frame.height - 8)
        count.frame.origin = CGPoint(x: bounds.width - count.frame.width - 14, y: bounds.height - count.frame.height - 9)
    }
}

#if DEBUG
/// `-autoScrollTest`: scrolls the main grid top to bottom twice (cold, then warm) in 4 s each, at display rate,
/// and logs frame timing, hitches and memory. Works for either grid (it drives the underlying UIScrollView).
@MainActor
enum ScrollBenchmark {
    static var engine: String {
        let a = ProcessInfo.processInfo.arguments
        return a.firstIndex(of: "-gridEngine").flatMap { a.indices.contains($0 + 1) ? a[$0 + 1] : nil } ?? "swiftui"
    }

    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-autoScrollTest") else { return }
        Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            await Driver.run(pass: "cold")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await Driver.run(pass: "warm")
            try? await Task.sleep(nanoseconds: 500_000_000)
            exit(0)
        }
    }

    private static func gridScrollView() -> UIScrollView? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        var best: UIScrollView?
        func walk(_ v: UIView) {
            if let s = v as? UIScrollView, s.contentSize.height > (best?.contentSize.height ?? 0) { best = s }
            v.subviews.forEach(walk)
        }
        windows.forEach(walk)
        return best
    }

    @MainActor private final class Driver: NSObject {
        private let scroll: UIScrollView
        private var link: CADisplayLink?
        private var start: CFTimeInterval = 0
        private var last: CFTimeInterval = 0
        private var gaps: [Double] = []
        private var nominal: Double = 1.0 / 60
        private var done: CheckedContinuation<Void, Never>?
        private let pass: String

        init(scroll: UIScrollView, pass: String) { self.scroll = scroll; self.pass = pass }

        static func run(pass: String) async {
            guard let scroll = ScrollBenchmark.gridScrollView() else { appLog("Benchmark: no grid"); return }
            scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
            try? await Task.sleep(nanoseconds: 300_000_000)
            let d = Driver(scroll: scroll, pass: pass)
            await withCheckedContinuation { cont in
                d.done = cont
                let link = CADisplayLink(target: d, selector: #selector(Driver.tick(_:)))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
                link.add(to: .main, forMode: .common)
                d.link = link
            }
        }

        @objc func tick(_ link: CADisplayLink) {
            if start == 0 { start = link.timestamp; last = link.timestamp; nominal = link.targetTimestamp - link.timestamp; return }
            gaps.append(link.timestamp - last)
            last = link.timestamp
            let t = min(1, (link.timestamp - start) / 4)
            let maxY = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
            scroll.contentOffset.y = -scroll.adjustedContentInset.top + (maxY + scroll.adjustedContentInset.top) * t
            guard t >= 1 else { return }
            link.invalidate()
            let sorted = gaps.sorted()
            let hitches = gaps.filter { $0 > nominal * 1.5 }.count
            let dropped = gaps.reduce(0) { $0 + max(0, Int(($1 / nominal).rounded()) - 1) }
            let ms = { (v: Double) in String(format: "%.1f", v * 1000) }
            appLog("Benchmark \(ScrollBenchmark.engine) \(pass): items \(ScrollBenchmark.itemCount) frames \(gaps.count) nominal \(ms(nominal)) ms avg \(ms(gaps.reduce(0, +) / Double(gaps.count))) p95 \(ms(sorted[Int(Double(sorted.count) * 0.95)])) max \(ms(sorted.last ?? 0)) hitches \(hitches) dropped \(dropped) memory \(ScrollBenchmark.memoryMB) MB")
            done?.resume()
            done = nil
        }
    }

    static var itemCount: Int { ((try? AppEnvironment.shared.store.counts()) ?? [:]).values.reduce(0, +) }

    static var memoryMB: Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }
}
#endif
