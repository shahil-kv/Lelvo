import SwiftUI
import LelvoCore

/// Search tab, like Photos: suggestions under an empty field, matching photos as a grid while typing.
struct SearchView: View {
    @EnvironmentObject private var gallery: GalleryModel
    @ObservedObject private var pro = ProStore.shared
    @StateObject private var search = SearchModel()
    @State private var showProPaywall = false

    var body: some View {
        NavigationStack {
            Group {
                if search.isSearching {
                    if search.needsProForQuery {
                        ContentUnavailableView {
                            Label("Smart Search", systemImage: "sparkle.magnifyingglass")
                        } description: {
                            Text("“\(search.query)” matches text or things in your photos. That needs Lelvo Pro. Places and dates stay free.")
                        } actions: {
                            Button("Unlock Smart Search") { showProPaywall = true }
                                .buttonStyle(.borderedProminent)
                        }
                    } else if search.results.isEmpty && search.isPending {
                        ProgressView()
                    } else if search.results.isEmpty {
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
            .searchable(text: $search.query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: pro.isPro ? "Places, dates, things, text" : "Places, dates, kinds")
            .onChange(of: search.query) { _, _ in search.run() }
            .onChange(of: pro.isPro) { _, _ in search.run() }
            .onSubmit(of: .search) { search.submit() }
            .task(id: gallery.revision) { search.update(entries: gallery.entries) }
            .task { search.load() }
            .sheet(isPresented: $showProPaywall) { ProPaywallView() }
        }
    }
}
