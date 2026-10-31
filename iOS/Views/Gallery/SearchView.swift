import SwiftUI
import LelvoCore

/// Search tab, like Photos: suggestions under an empty field, matching photos as a grid while typing.
struct SearchView: View {
    @EnvironmentObject private var gallery: GalleryModel
    @StateObject private var search = SearchModel()

    var body: some View {
        NavigationStack {
            Group {
                if search.isSearching {
                    if search.results.isEmpty {
                        EmptyStateView(systemImage: "magnifyingglass", title: "No Results",
                                       message: "Try a place, a month or year, or something in the photo.")
                    } else {
                        GalleryView(filter: .matching(title: search.query, ids: search.results), embedInNavigation: false)
                    }
                } else {
                    SearchSuggestions(search: search)
                }
            }
            .navigationTitle("Search")
            .settingsButton()
            .searchable(text: $search.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Places, dates, things, text")
            .onChange(of: search.query) { _, _ in search.run() }
            .onSubmit(of: .search) { if !search.results.isEmpty { search.remember(search.query) } }
            .task(id: gallery.revision) { search.update(entries: gallery.entries) }
            .task { search.load() }
        }
    }
}
