import SwiftUI
import LelvoCore

/// The tiles of Recently Deleted on the Mac: click to select.
struct TrashGrid: View {
    let items: [MediaItem]
    let selecting: Bool
    @Binding var selection: Set<String>
    let tapped: (String) -> Void

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 2)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(items) { item in
                    TrashTile(item: item, selecting: selecting, isSelected: selection.contains(item.id))
                        .onTapGesture { tapped(item.id) }
                }
            }
        }
    }
}
