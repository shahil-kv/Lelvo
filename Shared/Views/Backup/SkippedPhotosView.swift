import SwiftUI
import LelvoCore

/// Photos set aside as permanently unreadable. Retry skips them until the file on the phone changes.
struct SkippedPhotosView: View {
    @State private var rows: [LibraryStore.IgnoredAsset] = []
    @State private var loaded = false
    @State private var busy = false

    var body: some View {
        Form {
            if rows.isEmpty {
                if loaded {
                    ContentUnavailableView(
                        "Nothing Skipped",
                        systemImage: "checkmark.icloud",
                        description: Text("When a photo on this \(Device.name) can't be read, Lelvo sets it aside here instead of failing forever.")
                    )
                }
            } else {
                Section {
                    Button {
                        tryAgain(rows)
                    } label: {
                        Label("Try all again", systemImage: "arrow.clockwise")
                    }
                    .disabled(busy)
                } footer: {
                    Text("These photos couldn't be read, so automatic backup and Retry skip them until they change. Try again if you fixed the file or restored it from iCloud.")
                }
                Section("\(rows.count) skipped") {
                    ForEach(rows, id: \.localIdentifier) { row in
                        HStack(spacing: 12) {
                            FailedThumbnail(localIdentifier: row.localIdentifier)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.reason).font(.subheadline)
                                Text(Format.date(row.ignoredAt, style: .medium, time: .short))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button("Try again") { tryAgain([row]) }
                                .buttonStyle(.bordered)
                                .disabled(busy)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Skipped photos")
        .inlineNavigationTitle()
        .task { await load() }
    }

    private func load() async {
        rows = await Task.detached(priority: .userInitiated) {
            (try? AppEnvironment.shared.store.ignoredAssets()) ?? []
        }.value
        loaded = true
    }

    private func tryAgain(_ chosen: [LibraryStore.IgnoredAsset]) {
        busy = true
        Task {
            let ids = chosen.map(\.localIdentifier)
            await Task.detached {
                let store = AppEnvironment.shared.store
                for id in ids { try? store.unignoreAsset(localIdentifier: id) }
                _ = AppEnvironment.shared.engine.enqueue(localIdentifiers: ids)
            }.value
            ContinuedBackup.start()
            Haptics.success()
            let n = ids.count
            ToastCenter.shared.show(.info, "Trying \(n) photo\(n == 1 ? "" : "s") again",
                                    detail: "Progress is on the Backup page.")
            await load()
            busy = false
        }
    }
}
