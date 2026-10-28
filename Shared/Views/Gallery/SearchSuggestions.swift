import SwiftUI

/// Under an empty search field, like Photos and Google Photos: your recent searches first, then places and months.
/// Each section shows its first few; Show More opens the rest.
struct SearchSuggestions: View {
    @ObservedObject var search: SearchModel
    @State private var expanded: Set<String> = []
    private static let shown = 4

    var body: some View {
        List {
            if !search.recent.isEmpty {
                section("Recent", items: search.recent, symbol: "clock.arrow.circlepath") {
                    Button("Clear", role: .destructive) { search.clearRecent() }.font(.footnote)
                }
            }
            if !search.places.isEmpty { section("Places", items: search.places, symbol: "mappin.and.ellipse") }
            if !search.months.isEmpty { section("Months", items: search.months, symbol: "calendar") }
            Section {
                ForEach(["Videos", "Favorites", "Screenshots"], id: \.self) { kind in
                    row(kind, symbol: "magnifyingglass")
                }
            } header: { Text("Try") } footer: { Text(search.status) }
        }
    }

    private func section(_ title: String, items: [String], symbol: String,
                         @ViewBuilder trailing: () -> some View = { EmptyView() }) -> some View {
        let open = expanded.contains(title)
        return Section {
            ForEach(open ? items : Array(items.prefix(Self.shown)), id: \.self) { row($0, symbol: symbol) }
            if items.count > Self.shown {
                Button(open ? "Show Less" : "Show More") {
                    withAnimation { if open { expanded.remove(title) } else { expanded.insert(title) } }
                }
                .font(.subheadline)
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                trailing()
            }
        }
    }

    private func row(_ text: String, symbol: String) -> some View {
        Button { search.choose(text) } label: { Label(text, systemImage: symbol).foregroundStyle(.primary) }
    }
}
