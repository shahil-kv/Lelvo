import SwiftUI
import LelvoCore

/// Search in the sidebar, like Photos for Mac: suggestions under an empty field, matching photos as a grid while typing.
struct MacSearchView: View {
    @EnvironmentObject private var gallery: GalleryModel
    @ObservedObject private var pro = ProStore.shared
    @StateObject private var search = SearchModel()
    @State private var showProPaywall = false

    var body: some View {
        Group {
            if !search.isSearching {
                MacSearchSuggestions(search: search)
            } else if search.needsProForQuery {
                ContentUnavailableView {
                    Label("Smart Search", systemImage: "sparkle.magnifyingglass")
                } description: {
                    Text("“\(search.query)” matches text or things in your photos. That needs Lelvo Pro. Places and dates stay free.")
                } actions: {
                    Button("Unlock Smart Search") { showProPaywall = true }
                        .buttonStyle(.borderedProminent)
                }
            } else if !search.results.isEmpty {
                MacGalleryView(item: .search, filter: .matching(title: search.query, ids: search.results))
            } else if search.isPending {
                Color.clear
            } else {
                EmptyStateView(systemImage: "magnifyingglass", title: "No Results",
                               message: ProStore.offered
                                   ? "Try a place, a month or year, or something in the photo."
                                   : "Try a place, a month or year, or a kind of photo.")
            }
        }
        .navigationTitle("Search")
        .searchable(text: $search.query, placement: .toolbar,
                    prompt: pro.isPro ? "Places, dates, things, text" : "Places, dates, kinds")
        .onChange(of: search.query) { _, _ in search.run() }
        .onChange(of: pro.isPro) { _, _ in search.run() }
        .onSubmit(of: .search) { search.submit() }
        .task(id: gallery.revision) { search.update(entries: gallery.entries) }
        .task { search.load() }
        .sheet(isPresented: $showProPaywall) { ProPaywallView() }
    }
}
