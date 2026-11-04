#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// What a photo grid shows, built away from the main thread when the library is large: adding 100,000 ids to a
/// snapshot held the main thread for seconds, with the whole app frozen.
struct GridSnapshot: @unchecked Sendable {
    /// Below this, building is quick and the grid can stay in step with the view that asked for it.
    static let backgroundBuildAbove = 5_000

    let snapshot: NSDiffableDataSourceSnapshot<String, String>
    let entries: [String: GalleryEntry]
    let sections: [String: GallerySection]
    /// The sections in order. Asking the data source copies its whole snapshot, every id included, which at 100,000
    /// items is too slow to do for each header that scrolls into view.
    let sectionIds: [String]

    init(_ list: [GallerySection]) {
        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        var entries: [String: GalleryEntry] = [:]
        var sections: [String: GallerySection] = [:]
        snapshot.appendSections(list.map(\.id))
        for s in list {
            sections[s.id] = s
            snapshot.appendItems(s.entries.map(\.id), toSection: s.id)
            for e in s.entries { entries[e.id] = e }
        }
        self.snapshot = snapshot
        self.entries = entries
        self.sections = sections
        sectionIds = list.map(\.id)
    }

    /// Builds `list` and hands it to `apply` on the main thread: at once when it's small, otherwise after building in
    /// the background. A newer build cancels an older one through `task`.
    @MainActor
    static func build(_ list: [GallerySection], task: inout Task<Void, Never>?, apply: @escaping @MainActor (GridSnapshot) -> Void) {
        task?.cancel()
        task = nil
        guard list.reduce(0, { $0 + $1.entries.count }) > backgroundBuildAbove else {
            apply(GridSnapshot(list))
            return
        }
        task = Task { @MainActor in
            let built = await Task.detached(priority: .userInitiated) { GridSnapshot(list) }.value
            guard !Task.isCancelled else { return }
            apply(built)
        }
    }
}
