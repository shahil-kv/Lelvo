import SwiftUI

/// The photos and videos a Takeout import uploaded, in the same grid as an album.
struct ImportedPhotosView: View {
    var filter: GalleryFilter

    var body: some View {
        GalleryView(filter: filter, embedInNavigation: false)
    }
}
