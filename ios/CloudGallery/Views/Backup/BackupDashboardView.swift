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

    var body: some View {
        NavigationStack {
            List {
                Section {
                    statusHeader
                    Button {
                        Haptics.tap()
                        ContinuedBackup.start()
                    } label: {
                        Label(activity.isRunning ? "Backing up…" : "Back up now", systemImage: "icloud.and.arrow.up.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(activity.isRunning)
                    .listRowSeparator(.hidden)
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
                    statRow("Backed up (verified)", stats.backedUp, "checkmark.icloud.fill", .green)
                    statRow("Only in the cloud", stats.cloudOnly, "icloud.fill", .cyan)
                    statRow("Waiting to upload", stats.pending, "arrow.up.circle", .blue)
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

    private var statusHeader: some View {
        let left = activity.isRunning && activity.total > 0 ? activity.remaining : stats.pending
        let upToDate = left == 0 && stats.failed == 0 && !activity.isRunning
        return HStack(spacing: 14) {
            Image(systemName: upToDate ? "checkmark.icloud.fill" : "icloud.and.arrow.up")
                .font(.system(size: 40))
                .foregroundStyle(upToDate ? .green : .blue)
                .symbolEffect(.pulse, isActive: activity.isRunning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(upToDate ? "Backup is up to date" : "\(left) item\(left == 1 ? "" : "s") left to back up").font(.headline)
                Text("To \(LibraryService.titleDefault)").font(.subheadline).foregroundStyle(.secondary)
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
                        AppEnvironment.shared.engine.retryFailed()
                        load()
                        ContinuedBackup.start()
                    } label: { Label("Retry all failed", systemImage: "arrow.clockwise") }
                }
                Section("\(items.count) failed") {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.filename).lineLimit(1)
                            Text(item.lastError ?? "Unknown error").font(.caption).foregroundStyle(.red)
                            Text("\(Format.date(item.creationDate, style: .medium, time: .none)) · \(item.attempts) attempt(s)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Failed uploads")
        .onAppear(perform: load)
    }

    private func load() { items = (try? AppEnvironment.shared.store.items(status: .failed)) ?? [] }
}
