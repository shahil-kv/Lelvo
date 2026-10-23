import SwiftUI
import Photos
import CloudGalleryCore

/// Smart albums (Videos, Live Photos, Favorites, Cloud only) plus device albums and album names
/// restored from the cloud.
struct AlbumsView: View {
    @EnvironmentObject private var model: GalleryModel
    @State private var albums: [(title: String, ids: Set<String>)] = []

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach([GalleryFilter.videos, .livePhotos, .favorites, .cloudOnly], id: \.self) { f in tile(f) }
                }
                .padding(.horizontal)
                if !albums.isEmpty {
                    Text("Albums").font(.title3.bold()).frame(maxWidth: .infinity, alignment: .leading).padding([.horizontal, .top])
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(albums, id: \.title) { a in tile(.album(title: a.title, localIds: a.ids)) }
                    }
                    .padding(.horizontal)
                }
            }
            .navigationTitle("Albums")
            .task { await loadAlbums() }
        }
    }

    private func tile(_ filter: GalleryFilter) -> some View {
        let matching = model.entries.filter(filter.matches)
        return NavigationLink {
            GalleryView(filter: filter, embedInNavigation: false)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                AlbumCover(entry: matching.first, symbol: symbol(filter))
                Text(filter.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                Text("\(matching.count)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(filter.title), \(matching.count) items")
    }

    private func symbol(_ f: GalleryFilter) -> String {
        switch f {
        case .videos: return "video"
        case .livePhotos: return "livephoto"
        case .favorites: return "heart"
        case .cloudOnly: return "icloud"
        case .album: return "photo.on.rectangle"
        }
    }

    private func loadAlbums() async {
        let env = AppEnvironment.shared
        let cloudNames = Set(model.entries.compactMap(\.item).flatMap { $0.albums ?? [] })
        let result: [(String, Set<String>)] = await Task.detached {
            var byTitle: [String: Set<String>] = [:]
            if PhotoLibraryService.hasAccess {
                PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil).enumerateObjects { c, _, _ in
                    var ids = Set<String>()
                    PHAsset.fetchAssets(in: c, options: nil).enumerateObjects { a, _, _ in ids.insert(a.localIdentifier) }
                    byTitle[c.localizedTitle ?? "Album", default: []].formUnion(ids)
                }
            }
            for name in cloudNames where byTitle[name] == nil { byTitle[name] = [] }
            _ = env
            return byTitle.map { ($0.key, $0.value) }.sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
        }.value
        albums = result.map { (title: $0.0, ids: $0.1) }
    }
}

private struct AlbumCover: View {
    let entry: GalleryEntry?
    let symbol: String
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task(id: entry?.id) {
            guard let entry else { image = nil; return }
            let env = AppEnvironment.shared
            if let asset = entry.asset {
                image = await env.photos.image(for: asset, targetSize: CGSize(width: 400, height: 400))
            } else if let item = entry.item {
                image = try? await env.media.thumbnail(for: item)
            }
        }
    }
}
