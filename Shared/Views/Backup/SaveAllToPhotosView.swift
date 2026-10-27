import SwiftUI
import MemvoCore
#if os(iOS)
import UIKit
#endif

/// Everything that's only in the cloud, back into Photos in one go (a new phone, or after Free Up Space). One item at a
/// time through `GalleryActions.saveToPhotos`; each saved item is linked to its new photo, so running it again
/// continues with the rest.
struct SaveAllToPhotosView: View {
    @State private var items: [MediaItem] = []
    @State private var loading = true
    @State private var freeBytes: Int64?
    @State private var running = false
    @State private var done = 0
    @State private var saved = 0
    @State private var failures: [String] = []
    @State private var cancelFlag = CancelFlag()
    @State private var confirm = false
    @State private var result: GalleryAlert?

    /// Saving downloads each file and Photos keeps its own copy: leave room beyond the files themselves.
    private static let margin: Int64 = 1 << 30
    private var needed: Int64 { items.reduce(0) { $0 + Self.bytes(of: $1) } }
    private var shortBy: Int64? {
        guard let freeBytes else { return nil }
        let short = needed + Self.margin - freeBytes
        return short > 0 ? short : nil
    }

    var body: some View {
        Form {
            Section {
                Label {
                    Text("Save every photo and video that's only in your Telegram library back to Photos on this \(Device.name), with their dates, places, favourites and albums. Nothing is removed from Telegram.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "square.and.arrow.down.on.square.fill").foregroundStyle(.blue)
                }
            }

            Section {
                LabeledContent("Only in the cloud", value: loading ? "…" : items.count.formatted())
                LabeledContent("Space needed", value: loading ? "…" : Format.bytes(needed))
                if let freeBytes { LabeledContent("Free on this \(Device.name)", value: Format.bytes(freeBytes)) }
            } footer: {
                if let shortBy {
                    Text("Not enough space: free up \(Format.bytes(shortBy)) more first, or save a few at a time from the grid.")
                        .foregroundStyle(.red)
                }
            }

            Section {
                if running {
                    ProgressView(value: Double(done), total: Double(max(items.count, 1))) {
                        Text("Saving \(min(done + 1, items.count)) of \(items.count)…")
                    }
                    Button("Stop", role: .cancel) { cancelFlag.cancel() }
                } else {
                    Button { confirm = true } label: {
                        Label("Save \(items.count) to Photos", systemImage: "square.and.arrow.down")
                    }
                    .disabled(loading || items.isEmpty || shortBy != nil)
                }
            } footer: {
                Text("Keep Memvo open while it saves. If it stops, tap again: what's already saved is skipped.")
            }

            if !failures.isEmpty {
                Section("\(failures.count) not saved") {
                    ForEach(Array(failures.prefix(50).enumerated()), id: \.offset) { Text($0.element).font(.footnote) }
                }
            }
        }
        .platformGroupedForm()
        .navigationTitle("Save All to Photos")
        .onAppear(perform: load)
        .onDisappear { cancelFlag.cancel() }
        .confirmationDialog("Save \(items.count) items (\(Format.bytes(needed))) to Photos?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Save to Photos") { Task { await run() } }
        }
        .alert(item: $result) { a in Alert(title: Text(a.title), message: Text(a.message)) }
    }

    static func bytes(of item: MediaItem) -> Int64 {
        item.fileSize + (item.pairedVideoSize ?? 0) + (item.hasEdit == true ? (item.editedSize ?? 0) : 0)
    }

    private func load() {
        loading = true
        Task.detached {
            let env = AppEnvironment.shared
            let all = ((try? env.store.items(status: .backedUp)) ?? []).filter(\.isViewableFromCloud)
            // On this device already: its own photo, or a copy linked to it.
            let aliased = Set(((try? env.store.aliases()) ?? []).filter { env.photos.asset(localIdentifier: $0.localIdentifier) != nil }.map(\.itemId))
            let present = env.photos.existingIdentifiers(all.compactMap(\.localIdentifier))
            let cloudOnly = all.filter { item in
                !aliased.contains(item.id) && !(item.localIdentifier.map(present.contains) ?? false)
            }
            let free = (try? URL(fileURLWithPath: NSHomeDirectory())
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage)
                .map { Int64($0) }
            await MainActor.run {
                items = cloudOnly
                freeBytes = free
                loading = false
            }
        }
    }

    private func run() async {
        cancelFlag = CancelFlag()
        running = true
        done = 0
        saved = 0
        failures = []
        let started = Date()
        appLog("Save all to Photos: \(items.count) items, \(Format.bytes(needed))")
        #if os(iOS)
        // iOS stops long work soon after the app leaves the screen; the screen staying on keeps it going.
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        #else
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Saving to Photos")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        #endif
        for item in items {
            if cancelFlag.isCancelled { break }
            do {
                try await GalleryActions.saveToPhotos(item)
                saved += 1
            } catch {
                failures.append("\(item.filename): \(error.localizedDescription)")
            }
            done += 1
        }
        running = false
        appLog(String(format: "Save all to Photos finished: %d saved, %d failed%@ in %.0f s", saved, failures.count,
                      cancelFlag.isCancelled ? ", stopped" : "", Date().timeIntervalSince(started)))
        if failures.isEmpty { Haptics.success() } else { Haptics.error() }
        result = GalleryAlert(title: cancelFlag.isCancelled ? "Stopped" : "Saved \(saved) to Photos",
                              message: failures.isEmpty ? "They're in Photos, linked to your backup." : "\(failures.count) couldn't be saved; see the list. Tap Save again to retry them.")
        load()
    }
}
