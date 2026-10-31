import SwiftUI
import LelvoCore

/// Search in the sidebar, like Photos for Mac: suggestions under an empty field, matching photos as a grid while typing.
struct MacSearchView: View {
    @EnvironmentObject private var gallery: GalleryModel
    @StateObject private var search = SearchModel()

    var body: some View {
        Group {
            if search.isSearching {
                if search.results.isEmpty {
                    EmptyStateView(systemImage: "magnifyingglass", title: "No Results",
                                   message: "Try a place, a month or year, or something in the photo.")
                } else {
                    MacGalleryView(item: .search, filter: .matching(title: search.query, ids: search.results))
                }
            } else {
                SearchSuggestions(search: search)
            }
        }
        .navigationTitle("Search")
        .searchable(text: $search.query, placement: .toolbar, prompt: "Places, dates, things, text")
        .onChange(of: search.query) { _, _ in search.run() }
        .onSubmit(of: .search) { if !search.results.isEmpty { search.remember(search.query) } }
        .task(id: gallery.revision) { search.update(entries: gallery.entries) }
        .task { search.load() }
    }
}
