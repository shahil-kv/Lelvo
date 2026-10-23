import SwiftUI
import Photos
import CloudGalleryCore

/// Like Photos: "My Albums" as square covers, then "Media Types" as a list. Empty albums are hidden.
struct AlbumsView: View {
    @EnvironmentObject private var model: GalleryModel
    @State private var albums: [(title: String, ids: Set<String>)] = []

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
    private let mediaTypes: [GalleryFilter] = [.videos, .livePhotos, .favorites, .cloudOnly]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    let shown = albums.compactMap { a -> (GalleryFilter, [GalleryEntry])? in
                        let f = GalleryFilter.album(title: a.title, localIds: a.ids)
                        let m = model.entries.filter(f.matches)
                        return m.isEmpty ? nil : (f, m)
                    }
                    if !shown.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            sectionTitle("My Albums")
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                                ForEach(shown, id: \.0.title) { f, matching in albumTile(f, matching) }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        sectionTitle("Media Types")
                        VStack(spacing: 0) {
                            ForEach(Array(mediaTypes.enumerated()), id: \.element) { i, f in
                                mediaRow(f)
                                if i < mediaTypes.count - 1 { Divider().padding(.leading, 52) }
                            }
                        }
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle("Albums")
            .task { await loadAlbums() }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.title3.bold()).accessibilityAddTraits(.isHeader)
    }

    private func albumTile(_ filter: GalleryFilter, _ matching: [GalleryEntry]) -> some View {
        NavigationLink {
            GalleryView(filter: filter, embedInNavigation: false)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                AlbumCover(entry: matching.first, symbol: symbol(filter))
                Text(filter.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1).padding(.top, 4)
                Text(matching.count.formatted()).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(filter.title), \(matching.count) items")
    }

    private func mediaRow(_ filter: GalleryFilter) -> some View {
        let count = model.entries.lazy.filter(filter.matches).count
        return NavigationLink {
            GalleryView(filter: filter, embedInNavigation: false)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol(filter)).font(.body).foregroundStyle(.tint).frame(width: 24)
                Text(filter.title).foregroundStyle(.primary)
                Spacer()
                Text(count.formatted()).foregroundStyle(.secondary).monospacedDigit()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(filter.title), \(count) items")
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
            return byTitle.map { ($0.key, $0.value) }.sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
        }.value
        albums = result.map { (title: $0.0, ids: $0.1) }
    }
}

/// Square cover that always fills its tile (never overflows into neighbours).
private struct AlbumCover: View {
    let entry: GalleryEntry?
    let symbol: String
    @State private var image: UIImage?

    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .task(id: entry?.id) {
                guard let entry else { image = nil; return }
                let env = AppEnvironment.shared
                if let asset = entry.asset {
                    image = await env.photos.image(for: asset, targetSize: CGSize(width: 500, height: 500))
                } else if let item = entry.item {
                    image = try? await env.media.thumbnail(for: item)
                }
            }
    }
}
