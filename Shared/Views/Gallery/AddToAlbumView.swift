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
                    Text("\(count.formatted()) item\(count == 1 ? "" : "s"). Items only in your Telegram library are saved to Photos first. Albums are in beta: they're kept in Photos on this device and don't reach your other devices yet.")
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
            albums = await Task.detached(priority: .userInitiated) { AppEnvironment.shared.photos.editableAlbums() }.value
            loaded = true
        }
    }

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
