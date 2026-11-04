import SwiftUI
import LelvoCore

/// Under an empty search field on the Mac: suggestions as a tidy grid of rows that light up under the pointer, like
/// Photos and Spotlight. The iPhone's list turns into a stack of bordered buttons here.
struct MacSearchSuggestions: View {
    @ObservedObject var search: SearchModel
    @State private var expanded: Set<String> = []
    private static let shown = 8
    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 360), spacing: 8, alignment: .leading)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if !search.recent.isEmpty {
                    section("Recent", items: search.recent, symbol: "clock.arrow.circlepath") {
                        Button("Clear") { search.clearRecent() }.buttonStyle(.link)
                    }
                }
                if !search.places.isEmpty { section("Places", items: search.places, symbol: "mappin.and.ellipse") }
                if !search.months.isEmpty { section("Months", items: search.months, symbol: "calendar") }
                section("Try", items: ["Videos", "Favorites", "Screenshots"], symbol: "magnifyingglass")
                Text(search.status).font(.callout).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section(_ title: String, items: [String], symbol: String,
                         @ViewBuilder trailing: () -> some View = { EmptyView() }) -> some View {
        let open = expanded.contains(title)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                trailing()
                if items.count > Self.shown {
                    Button(open ? "Show Less" : "Show More") {
                        withAnimation(.snappy) { if open { expanded.remove(title) } else { expanded.insert(title) } }
                    }
                    .buttonStyle(.link)
                }
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                ForEach(open ? items : Array(items.prefix(Self.shown)), id: \.self) { text in
                    SuggestionRow(text: text, symbol: symbol) { search.choose(text) }
                }
            }
        }
    }
}

private struct SuggestionRow: View {
    let text: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(.tint).frame(width: 20)
                Text(text).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
