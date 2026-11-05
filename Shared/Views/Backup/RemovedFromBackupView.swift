import SwiftUI
import Photos
import LelvoCore

/// A photo still on this device that the user deleted from the backup.
struct RemovedPhoto: Identifiable, Sendable {
    let id: String
    let date: Date?
    /// Its files are still in the channel, so backing it up recovers it. Otherwise it has to upload again.
    let inRecentlyDeleted: Bool
}

enum RemovedFromBackupModel {
    /// Reads the index and Photos, so call it off the main actor.
    static func photos() -> [RemovedPhoto] {
        let env = AppEnvironment.shared
        guard PhotoLibraryService.hasAccess, !DemoMode.isActive else { return [] }
        let trashed = (try? env.store.items(status: .trashed)) ?? []
        let offBackup = (try? env.store.offBackupLocalIdentifiers()) ?? []
        let inTrash = Set(trashed.compactMap(\.localIdentifier))
        let present = env.photos.existingIdentifiers(Array(inTrash.union(offBackup)))
        let ids = BackupCounts.removedFromBackup(trashed: trashed, offBackup: offBackup,
                                                 known: (try? env.store.knownLocalIdentifiers()) ?? [], present: Set(present))
        return ids.map { id in
            RemovedPhoto(id: id, date: env.photos.asset(localIdentifier: id)?.creationDate, inRecentlyDeleted: inTrash.contains(id))
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }
}

struct RemovedFromBackupView: View {
    @State private var photos: [RemovedPhoto] = []
    @State private var loaded = false
    @State private var busy = false

    var body: some View {
        Form {
            if photos.isEmpty {
                if loaded {
                    ContentUnavailableView("Nothing Removed", systemImage: "checkmark.icloud",
                                           description: Text("Photos you delete from your backup and keep on this \(Device.name) show up here."))
                }
            } else {
                Section {
                    Button {
                        backUp(photos)
                    } label: {
                        Label("Back up all \(photos.count)", systemImage: "icloud.and.arrow.up")
                    }
                    .disabled(busy)
                } footer: {
                    Text("You deleted these from your backup, and they're still on this \(Device.name). Back up now and automatic backup skip them until you choose to back them up here.")
                }
                Section("\(photos.count) removed") {
                    ForEach(photos) { photo in
                        HStack(spacing: 12) {
                            FailedThumbnail(localIdentifier: photo.id)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(Format.date(photo.date, style: .medium, time: .none))
                                Text(photo.inRecentlyDeleted ? "In Recently Deleted" : "Deleted from your Telegram library")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button("Back up") { backUp([photo]) }
                                .buttonStyle(.bordered)
                                .disabled(busy)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Removed from backup")
        .inlineNavigationTitle()
        .task { await load() }
    }

    private func load() async {
        photos = await Task.detached(priority: .userInitiated) { RemovedFromBackupModel.photos() }.value
        loaded = true
    }

    private func backUp(_ chosen: [RemovedPhoto]) {
        busy = true
        Task {
            let ids = chosen.map(\.id)
            let count = await Task.detached { AppEnvironment.shared.engine.enqueue(localIdentifiers: ids) }.value
            ContinuedBackup.start()
            Haptics.success()
            let items = "\(count) item\(count == 1 ? "" : "s")"
            if chosen.allSatisfy(\.inRecentlyDeleted) {
                ToastCenter.shared.show(.success, "\(items) back in your backup")
            } else {
                ToastCenter.shared.show(.info, "Backing up \(items)", detail: "Progress is on the Backup page.")
            }
            await load()
            busy = false
        }
    }
}
