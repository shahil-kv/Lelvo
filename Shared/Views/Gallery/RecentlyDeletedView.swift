import SwiftUI
import LelvoCore

/// Items deleted from the cloud, kept for 30 days like Photos' Recently Deleted (`CloudTrash`).
struct RecentlyDeletedView: View {
    @State private var items: [MediaItem] = []
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var confirmDelete: [MediaItem]?
    @State private var busy = false
    @State private var alert: GalleryAlert?

    private var selected: [MediaItem] { items.filter { selection.contains($0.id) } }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView("No Recently Deleted Items", systemImage: "trash",
                                       description: Text("Items you delete from your backup stay here for 30 days before they're removed from your Telegram library."))
            } else {
                VStack(spacing: 0) {
                    Text("Items stay here for 30 days, then they're removed from your Telegram library. Photos still on this \(Device.name) aren't affected.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    TrashGrid(items: items, selecting: selecting, selection: $selection) { id in
                        if !selecting { selecting = true }
                        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
                    }
                }
                .safeAreaInset(edge: .bottom) { actionBar }
            }
        }
        .navigationTitle("Recently Deleted")
        .inlineNavigationTitle()
        .toolbar {
            if !items.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button(selecting ? "Done" : "Select") {
                        selecting.toggle()
                        selection.removeAll()
                    }
                }
            }
        }
        .overlay { if busy { ProgressView() } }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete from Telegram", role: .destructive) {
                if let doomed = confirmDelete { Task { await delete(doomed) } }
            }
        } message: {
            Text("This can't be undone. Photos still on this \(Device.name) aren't affected.")
        }
        .alert(item: $alert) { a in Alert(title: Text(a.title), message: Text(a.message)) }
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: LibraryStore.didChange)) { _ in Task { await reload() } }
    }

    private var deleteTitle: String {
        let n = confirmDelete?.count ?? 0
        return n == 1 ? "Delete this item from your Telegram library?" : "Delete \(n) items from your Telegram library?"
    }

    private var actionBar: some View {
        let targets = selecting && !selection.isEmpty ? selected : items
        let all = !(selecting && !selection.isEmpty)
        return HStack {
            Button(all ? "Recover All" : "Recover") { Task { await recover(targets) } }
            Spacer()
            Button(all ? "Delete All" : "Delete", role: .destructive) { confirmDelete = targets }
                .foregroundStyle(.red)
        }
        .disabled(busy)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func reload() async {
        items = await Task.detached(priority: .userInitiated) { GalleryActions.trashedItems() }.value
        selection.formIntersection(items.map(\.id))
        // Emptied from another device: the button that ends selecting is gone with the items.
        if items.isEmpty { selecting = false }
    }

    private func recover(_ targets: [MediaItem]) async {
        busy = true
        defer { busy = false }
        do {
            try await Task.detached(priority: .userInitiated) { _ = try await GalleryActions.recover(targets) }.value
            Haptics.success()
            selection.removeAll()
            selecting = false
        } catch {
            alert = GalleryAlert(title: "Couldn't recover", message: error.localizedDescription)
        }
    }

    private func delete(_ targets: [MediaItem]) async {
        busy = true
        defer { busy = false }
        do {
            try await GalleryActions.deletePermanently(targets)
            Haptics.success()
            selection.removeAll()
            selecting = false
        } catch {
            Haptics.error()
            alert = GalleryAlert(title: "Couldn't delete", message: error.localizedDescription)
        }
    }
}

/// One tile of Recently Deleted. Tapping and swiping are the grid's (`TrashGrid`, one for each platform).
struct TrashTile: View {
    let item: MediaItem
    let selecting: Bool
    let isSelected: Bool

    var body: some View {
        let days = CloudTrash.daysLeft(item)
        Color.tileBackground
            .aspectRatio(1, contentMode: .fit)
            .overlay { TrashThumbnail(item: item).id(item.id) }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                Text(days == 1 ? "1 day" : "\(days) days")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .padding(5)
            }
            .overlay(alignment: .bottomTrailing) {
                if selecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : .white)
                        .background(Circle().fill(isSelected ? .white : .black.opacity(0.2)))
                        .padding(5)
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(item.kind == .video ? "Video" : "Photo"), \(Format.date(item.creationDate, style: .long, time: .short)), \(days == 1 ? "1 day" : "\(days) days") left")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct TrashThumbnail: View {
    let item: MediaItem
    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            if let image { Image(platformImage: image).resizable().scaledToFill() }
        }
        .task(id: item.id) { image = try? await AppEnvironment.shared.media.thumbnail(for: item) }
    }
}
