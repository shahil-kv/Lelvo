import SwiftUI

/// The photos and videos a Takeout import uploaded, in the same grid as search results.
struct ImportedPhotosView: View {
    var filter: GalleryFilter

    var body: some View {
        MacGalleryView(item: .search, filter: filter)
    }
}
