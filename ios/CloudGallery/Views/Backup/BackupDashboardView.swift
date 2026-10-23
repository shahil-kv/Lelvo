import SwiftUI
import Photos
import CloudGalleryCore

@MainActor
final class BackupStatsModel: ObservableObject {
    @Published var backedUp = 0
    @Published var pending = 0
    @Published var failed = 0
    @Published var cloudOnly = 0
    @Published var onDevice = 0
    @Published var notQueued = 0
    private var observer: NSObjectProtocol?
    private var pendingRefresh: Task<Void, Never>?

    init() {
        observer = NotificationCenter.default.addObserver(forName: LibraryStore.didChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh() }
        }
    }

    /// The store changes constantly during a backup; recount at most every 2 s.
    func scheduleRefresh() {
        guard pendingRefresh == nil else { return }
        pendingRefresh = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            pendingRefresh = nil
            refresh()
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    /// Accurate counts: verified items only count as backed up (#17).
    func refresh() {
        let env = AppEnvironment.shared
        Task.detached {
            let counts = (try? env.store.counts()) ?? [:]
            let all = (try? env.store.items(status: .backedUp)) ?? []
            var onDevice = 0, notQueued = 0, cloudOnly = 0
            if PhotoLibraryService.hasAccess {
                let assets = env.photos.fetchAllAssets()
                onDevice = assets.count
                let known = (try? env.store.knownLocalIdentifiers()) ?? []
                notQueued = env.photos.backupCandidates().filter { !known.contains($0.localIdentifier) }.count
                let present = env.photos.existingIdentifiers(all.compactMap(\.localIdentifier))
                cloudOnly = all.filter { $0.localIdentifier.map { !present.contains($0) } ?? true }.count
            } else {
                cloudOnly = all.count
            }
            await MainActor.run {
                self.backedUp = counts[.backedUp] ?? 0
                self.pending = (counts[.queued] ?? 0) + (counts[.uploading] ?? 0) + notQueued
                self.failed = counts[.failed] ?? 0
                self.cloudOnly = cloudOnly
                self.onDevice = onDevice
                self.notQueued = notQueued
            }
        }
    }
}

struct BackupDashboardView: View {
    @EnvironmentObject private var activity: BackupActivity
    @EnvironmentObject private var app: AppModel
    @StateObject private var stats = BackupStatsModel()
    @AppStorage(Prefs.Key.wifiOnly) private var wifiOnly = true
    @AppStorage(Prefs.Key.chargingOnly) private var chargingOnly = false
    @AppStorage(Prefs.Key.backupPaused) private var paused = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    statusHeader
                    if activity.isRunning {
                        Button(role: .destructive) {
                            Haptics.tap()
                            AppEnvironment.shared.engine.pause()
                        } label: {
                            Label("Pause backup", systemImage: "pause.circle.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .listRowSeparator(.hidden)
                    } else if stats.pending > 0 {
                        Button {
                            Haptics.tap()
                            ContinuedBackup.start()
                        } label: {
                            Label(paused ? "Resume backup" : "Back up now", systemImage: "icloud.and.arrow.up.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .listRowSeparator(.hidden)
                        if paused {
                            Label("Paused. Shortcuts and overnight backups won't run until you resume.", systemImage: "pause.circle")
                                .font(.footnote).foregroundStyle(.orange)
                        }
                    } else if stats.failed > 0 {
                        Button {
                            Haptics.tap()
                            Task {
                                await Task.detached { AppEnvironment.shared.engine.retryFailed() }.value
                                ContinuedBackup.start()
                            }
                        } label: {
                            Label("Retry \(stats.failed) failed", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .listRowSeparator(.hidden)
                    }
                    if activity.isRunning && activity.total > 0 {
                        ProgressView(value: Double(activity.done), total: Double(max(activity.total, 1))) {
                            Text("\(activity.done) of \(activity.total) done · \(activity.remaining) left")
                                .font(.subheadline.monospacedDigit())
                        }
                        if let notice = activity.notice {
                            Label(notice, systemImage: "hourglass").font(.caption).foregroundStyle(.orange)
                        }
                        if activity.failed > 0 {
                            Text("\(activity.failed) failed in this run (see Failed below)").font(.caption).foregroundStyle(.red)
                        }
                        ForEach(activity.lanes.sorted(by: { $0.key < $1.key }), id: \.key) { _, lane in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: "arrow.up.circle").foregroundStyle(.blue)
                                    Text(lane.name).lineLimit(1)
                                    Spacer()
                                    if lane.total > 0 {
                                        Text("\(Format.bytes(lane.sent)) of \(Format.bytes(lane.total))")
                                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    } else {
                                        Text("Preparing…").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .font(.footnote)
                                if lane.total > 0 {
                                    ProgressView(value: Double(lane.sent), total: Double(lane.total))
                                }
                            }
                        }
                    }
                    if headerState == .running || headerState == .pending {
                        if let message = activity.message, !(activity.isRunning && activity.total > 0) {
                            Text(message).font(.footnote).foregroundStyle(.secondary)
                        }
                        if wifiOnly || chargingOnly {
                            Label([wifiOnly ? "Wi-Fi only" : nil, chargingOnly ? "charging only" : nil].compactMap { $0 }.joined(separator: ", ") + ". Change in Settings.",
                                  systemImage: "slider.horizontal.3")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Text("Keep CloudGallery open for big first backups. On iOS 26+, “Back up now” keeps running in the background with progress on the Lock Screen.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if PhotoLibraryService.authorizationStatus == .limited {
                    Section {
                        Label("Limited photo access: only photos you selected are backed up.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Button("Allow full access in Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                }

                Section("Library") {
                    statRow("On this iPhone", stats.onDevice, "iphone", .secondary)
                    statRow("Backed up (verified)", stats.backedUp, BackupBadge.backedUp.symbol, BackupBadge.backedUp.tint)
                    statRow("Only in the cloud", stats.cloudOnly, BackupBadge.cloudOnly.symbol, BackupBadge.cloudOnly.tint)
                    statRow("Waiting to upload", stats.pending, BackupBadge.waiting.symbol, .secondary)
                    NavigationLink { FailedItemsView() } label: {
                        statRow("Failed", stats.failed, "exclamationmark.icloud.fill", stats.failed > 0 ? .red : .secondary)
                    }
                }

                Section("Tools") {
                    NavigationLink { FreeUpSpaceView() } label: { Label("Free up space", systemImage: "internaldrive") }
                    NavigationLink { AutomationGuideView() } label: { Label("Shortcuts automations", systemImage: "bolt.badge.clock") }
                    Button {
                        Task {
                            _ = try? await AppEnvironment.shared.library.scan(full: true)
                            stats.refresh()
                        }
                    } label: { Label("Re-scan the Telegram library", systemImage: "arrow.triangle.2.circlepath") }
                }
            }
            .navigationTitle("Backup")
            .navigationDestination(isPresented: $app.showFreeUpSpace) { FreeUpSpaceView() }
            .refreshable { stats.refresh() }
            .onAppear { stats.refresh() }
            .onChange(of: activity.isRunning) { _, _ in stats.refresh() }
        }
    }

    private enum HeaderState { case running, complete, completeWithFailures, pending }

    private var headerState: HeaderState {
        if activity.isRunning { return .running }
        if stats.pending > 0 { return .pending }
        return stats.failed > 0 ? .completeWithFailures : .complete
    }

    /// Mirrors Google Photos: "Backup complete" when nothing is left, failures called out separately.
    private var statusHeader: some View {
        let left = activity.isRunning && activity.total > 0 ? activity.remaining : stats.pending
        let state = headerState
        let icon: String, tint: Color, title: String
        switch state {
        case .complete:
            (icon, tint, title) = ("checkmark.icloud.fill", .green, "Backup complete")
        case .completeWithFailures:
            (icon, tint, title) = ("exclamationmark.icloud.fill", .orange,
                                   "Backup complete, \(stats.failed) item\(stats.failed == 1 ? "" : "s") couldn't be backed up")
        case .running, .pending:
            (icon, tint, title) = ("icloud.and.arrow.up", .blue, "\(left) item\(left == 1 ? "" : "s") left to back up")
        }
        return HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(tint)
                .symbolEffect(.pulse, isActive: activity.isRunning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(state == .complete ? "Everything on this iPhone is in \(LibraryService.titleDefault)" : "To \(LibraryService.titleDefault)")
                    .font(.subheadline).foregroundStyle(.secondary)
                if let last = UserDefaults.standard.object(forKey: Prefs.Key.lastBackupAt) as? Date {
                    Text("Last upload \(Format.relative(last))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private func statRow(_ title: String, _ value: Int, _ icon: String, _ color: Color) -> some View {
        HStack {
            Label { Text(title) } icon: { Image(systemName: icon).foregroundStyle(color) }
            Spacer()
            Text("\(value)").monospacedDigit().foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Every failed item with its reason, and a Retry button. No silent failures (#22).
struct FailedItemsView: View {
    @State private var items: [MediaItem] = []

    var body: some View {
        List {
            if items.isEmpty {
                EmptyStateView(systemImage: "checkmark.circle", title: "Nothing failed", message: "Every attempted upload went through.")
            } else {
                Section {
                    Button {
                        Task {
                            await Task.detached { AppEnvironment.shared.engine.retryFailed() }.value
                            await load()
                            ContinuedBackup.start()
                        }
                    } label: { Label("Retry all failed", systemImage: "arrow.clockwise") }
                }
                Section("\(items.count) failed") {
                    ForEach(items) { item in
                        HStack(spacing: 12) {
                            FailedThumbnail(localIdentifier: item.localIdentifier)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.filename).lineLimit(1)
                                Text(item.lastError ?? "Unknown error").font(.caption).foregroundStyle(.red)
                                Text("\(Format.date(item.creationDate, style: .medium, time: .none)) · \(item.attempts) attempt(s)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            if let id = item.localIdentifier {
                                Button(role: .destructive) {
                                    Task {
                                        // iOS asks for confirmation; the item is then dropped from the queue.
                                        guard (try? await AppEnvironment.shared.photos.deleteAssets([id])) != nil else { return }
                                        await Task.detached { try? AppEnvironment.shared.store.delete(id: item.id) }.value
                                        await load()
                                    }
                                } label: { Label("Delete from iPhone", systemImage: "trash") }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Failed uploads")
        .task { await load() }
    }

    /// Off the main thread: the store can be busy with upload checkpoints.
    private func load() async {
        items = await Task.detached { (try? AppEnvironment.shared.store.items(status: .failed)) ?? [] }.value
    }
}

private struct FailedThumbnail: View {
    let localIdentifier: String?
    @State private var image: UIImage?

    var body: some View {
        Color(.secondarySystemBackground)
            .frame(width: 52, height: 52)
            .overlay { if let image { Image(uiImage: image).resizable().scaledToFill() } }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .task(id: localIdentifier) {
                let env = AppEnvironment.shared
                guard let localIdentifier, let asset = env.photos.asset(localIdentifier: localIdentifier) else { return }
                image = await env.photos.image(for: asset, targetSize: CGSize(width: 156, height: 156))
            }
    }
}
