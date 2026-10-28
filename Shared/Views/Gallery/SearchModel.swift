import SwiftUI
import MemvoCore

/// The search field's state: results (timeline entry ids) for the current text, computed off the main thread a moment
/// after typing stops, plus suggestions and how far the index has got.
@MainActor
final class SearchModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var results: Set<String> = []
    @Published private(set) var places: [String] = []
    @Published private(set) var months: [String] = []
    /// What was searched before, newest first (kept on this device only).
    @Published private(set) var recent: [String] = UserDefaults.standard.stringArray(forKey: SearchModel.recentKey) ?? []
    private static let recentKey = "recentSearches"
    @Published private(set) var status = ""
    private var task: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private var index = SearchIndex.empty
    private var entries: [GalleryEntry] = []
    private var corpusTask: Task<Void, Never>?

    init() {
        observer = NotificationCenter.default.addObserver(forName: SearchService.didIndex, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStatus()
                self?.rebuild()
            }
        }
    }

    /// The timeline changed: rebuild the word list (off the main thread), then search again.
    func update(entries: [GalleryEntry]) {
        self.entries = entries
        rebuild()
    }

    private func rebuild() {
        corpusTask?.cancel()
        let entries = self.entries
        let search = AppEnvironment.shared.search!
        corpusTask = Task {
            let (built, suggested) = await Task.detached(priority: .userInitiated) {
                (search.index(for: entries), search.suggestions(for: entries))
            }.value
            guard !Task.isCancelled else { return }
            index = built
            places = suggested.places
            months = suggested.months
            run()
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    var isSearching: Bool { !SearchMatcher.words(query).isEmpty }

    /// A suggestion was tapped: search for it.
    func choose(_ text: String) {
        query = text
        remember(text)
    }

    /// Keeps a search that found something, so it's offered next time.
    func remember(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        recent = [clean] + recent.filter { $0.caseInsensitiveCompare(clean) != .orderedSame }
        recent = Array(recent.prefix(20))
        UserDefaults.standard.set(recent, forKey: Self.recentKey)
    }

    func clearRecent() {
        recent = []
        UserDefaults.standard.removeObject(forKey: Self.recentKey)
    }

    func run() {
        task?.cancel()
        let text = query
        guard !SearchMatcher.words(text).isEmpty else { results = []; return }
        let index = self.index
        task = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .userInitiated) { index.search(text) }.value
            guard !Task.isCancelled, text == query else { return }
            let set = Set(found)
            if set != results { results = set }
        }
    }

    func load() {
        let search = AppEnvironment.shared.search!
        refreshStatus()
        search.indexInForeground()
    }

    private func refreshStatus() {
        let s = AppEnvironment.shared.search.status
        if s.total == 0 || s.indexed >= s.total {
            status = "Search looks at places, dates, and text and things in your photos, on this \(Device.name)."
        } else {
            status = "\(s.indexed.formatted()) of \(s.total.formatted()) photos read for search. Reading continues while Memvo is open."
        }
    }
}
