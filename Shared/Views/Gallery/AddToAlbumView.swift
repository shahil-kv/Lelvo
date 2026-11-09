import SwiftUI
import Photos

/// Photos' Add To sheet: New Album first, then the user's own albums with their covers. It only picks the album (making
/// it if new); the caller adds the items, so the grid can show progress and the result in its own way.
struct AddToAlbumView: View {
    let count: Int
    /// The chosen album's local identifier and title.
    let onPick: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var albums: [(album: AlbumInfo, coverId: String?)] = []
    @State private var loaded = false
    @State private var naming = false
    @State private var newName = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { newName = ""; naming = true } label: {
                        Label("New Album…", systemImage: "plus.rectangle.on.rectangle")
                    }
                } footer: {
                    Text("\(count.formatted()) item\(count == 1 ? "" : "s"). Items only in your Telegram library stay there and join the album in Photos when you save them. Albums are in beta.")
                }
                if !albums.isEmpty {
                    Section("My Albums") {
                        ForEach(albums, id: \.album.id) { entry in
                            Button { pick(entry.album.id, entry.album.title) } label: { AlbumRow(album: entry.album, coverId: entry.coverId) }
                                .buttonStyle(.plain)
                        }
                    }
                } else if !loaded {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Add to Album")
            .toolbar { ToolbarItem(placement: .principal) { HStack(spacing: 6) { Text("Add to Album").font(.headline); BetaTag() } } }
            .inlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .alert("New Album", isPresented: $naming) {
                TextField("Title", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Save") { Task { await create() } }
            } message: {
                Text("Enter a name for this album.")
            }
            .alert("Couldn't make the album", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
        }
        .macSheetSize(width: 400, height: 480)
        .task {
            // Counting each album's items is a PhotoKit fetch: off the main actor.
            albums = await Task.detached(priority: .userInitiated) { Self.allAlbums() }.value
            loaded = true
        }
    }

    /// Photos' albums, plus albums that so far hold only items in the Telegram library (made on another device, or
    /// whose Photos album was deleted). Counts include those items, as Lelvo's albums show them.
    nonisolated private static func allAlbums() -> [(album: AlbumInfo, coverId: String?)] {
        var list = AppEnvironment.shared.photos.editableAlbums()
        var cloudOnly: [String: Int] = [:]
        for item in (try? AppEnvironment.shared.store.allItems()) ?? [] where item.localIdentifier == nil && item.status == .backedUp {
            for name in item.albums ?? [] { cloudOnly[name, default: 0] += 1 }
        }
        list = list.map { (AlbumInfo(id: $0.album.id, title: $0.album.title, count: $0.album.count + (cloudOnly[$0.album.title] ?? 0)), $0.coverId) }
        let inPhotos = Set(list.map(\.album.title))
        let extra = cloudOnly.filter { !inPhotos.contains($0.key) }.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
        return list + extra.map { (AlbumInfo(id: Self.cloudOnlyPrefix + $0.key, title: $0.key, count: $0.value), nil) }
    }

    /// Ids of albums with no Photos album yet. Never a PhotoKit identifier, which has no such prefix.
    nonisolated private static let cloudOnlyPrefix = "lelvo-cloud-album:"

    private func create() async {
        let title = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = title.isEmpty ? "New Album" : title
        do {
            let id = try await Task.detached { try await AppEnvironment.shared.photos.createAlbum(titled: name) }.value
            pick(id, name)
        } catch {
            Haptics.error()
            self.error = "Photos didn't make the album. Check that Lelvo has full access to your photos, then try again."
        }
    }

    private func pick(_ id: String, _ title: String) {
        // An album only in the Telegram library gets its Photos album now, so items on this device can join it.
        guard !id.hasPrefix(Self.cloudOnlyPrefix) else {
            newName = title
            Task { await create() }
            return
        }
        Haptics.selection()
        dismiss()
        onPick(id, title)
    }
}

private struct AlbumRow: View {
    let album: AlbumInfo
    let coverId: String?
    @State private var cover: PlatformImage?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Color.tileBackground
                if let cover {
                    Image(platformImage: cover).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo.on.rectangle").foregroundStyle(.secondary)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title).foregroundStyle(.primary)
                Text(album.count.formatted()).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(album.title), \(album.count) items")
        .task(id: coverId) {
            guard let coverId else { return }
            cover = await Task.detached(priority: .utility) { () -> PlatformImage? in
                let photos = AppEnvironment.shared.photos
                guard let asset = photos.asset(localIdentifier: coverId) else { return nil }
                return await photos.image(for: asset, targetSize: CGSize(width: 168, height: 168))
            }.value
        }
    }
}
