import SwiftUI
import Photos
import CloudGalleryCore

@MainActor
final class BackupStatsModel: ObservableObject {
    @Published var counts: [ItemStatus: Int] = [:]
    @Published var phoneOnly = 0
    @Published var indexUploadedAt: Date?
    @Published var indexDirty = false
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: LibraryStore.didChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func refresh() {
        let env = AppEnvironment.shared
        counts = (try? env.store.counts()) ?? [:]
        indexUploadedAt = env.indexSync.lastUploadedAt
        indexDirty = env.engine.isIndexDirty
        Task.detached {
            guard PhotoLibraryService.hasAccess else { return }
            let known = (try? env.store.knownLocalIdentifiers()) ?? []
            let pending = env.photos.backupCandidates().filter { !known.contains($0.localIdentifier) }.count
            await MainActor.run { self.phoneOnly = pending }
        }
    }
}

struct BackupDashboardView: View {
    @EnvironmentObject private var activity: BackupActivity
    @EnvironmentObject private var app: AppModel
    @StateObject private var stats = BackupStatsModel()
    @AppStorage(Prefs.Key.wifiOnly) private var wifiOnly = true
    @AppStorage(Prefs.Key.chatTitle) private var chatTitle = ""
    @State private var syncingIndex = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    statusHeader
                    Button {
                        Haptics.tap()
                        ContinuedBackup.start()
                    } label: {
                        Label(activity.isPreparing ? "Backing up…" : "Back up now", systemImage: "icloud.and.arrow.up.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(activity.isPreparing)
                    .listRowSeparator(.hidden)
                    if activity.isPreparing {
                        ProgressView(value: Double(activity.prepared), total: Double(max(activity.total, 1))) {
                            Text("Preparing \(activity.prepared) of \(activity.total)")
                        }
                    } else if let message = activity.message {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                    if wifiOnly {
                        Label("Uploads wait for Wi-Fi. Change this in Settings.", systemImage: "wifi")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                if PhotoLibraryService.authorizationStatus == .limited {
                    Section {
                        Label("Limited photo access: only photos you selected are backed up.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Button("Allow full access in Settings") {
                            UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                        }
                    }
                }

                Section("Library") {
                    statRow("Backed up", stats.counts[.backedUp] ?? 0, "checkmark.icloud.fill", .green)
                    statRow("Waiting on phone", stats.phoneOnly, "iphone", .secondary)
                    statRow("Uploading", (stats.counts[.uploading] ?? 0) + (stats.counts[.queued] ?? 0), "arrow.up.circle", .blue)
                    if (stats.counts[.failed] ?? 0) > 0 {
                        statRow("Failed (retried next run)", stats.counts[.failed] ?? 0, "exclamationmark.icloud.fill", .red)
                    }
                    NavigationLink {
                        LargeFilesView()
                    } label: {
                        statRow("Needs version 2 (large files)", stats.counts[.tooLarge] ?? 0, "exclamationmark.triangle.fill", .orange)
                    }
                }

                Section("Cloud index") {
                    LabeledContent("Last uploaded", value: Format.relative(stats.indexUploadedAt))
                    if stats.indexDirty { Text("Changes waiting to be saved to the index.").font(.footnote).foregroundStyle(.secondary) }
                    Button {
                        Task {
                            syncingIndex = true
                            defer { syncingIndex = false }
                            do { try await AppEnvironment.shared.indexSync.upload(); Haptics.success() }
                            catch { self.error = error.localizedDescription; Haptics.error() }
                            stats.refresh()
                        }
                    } label: {
                        HStack { Text("Upload index now"); if syncingIndex { Spacer(); ProgressView() } }
                    }
                    .disabled(syncingIndex)
                    if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                }

                Section("Tools") {
                    NavigationLink { FreeUpSpaceView() } label: { Label("Free up space", systemImage: "internaldrive") }
                    NavigationLink { AutomationGuideView() } label: { Label("Shortcuts automations", systemImage: "bolt.badge.clock") }
                }
            }
            .navigationTitle("Backup")
            .navigationDestination(isPresented: $app.showFreeUpSpace) { FreeUpSpaceView() }
            .refreshable { stats.refresh() }
            .onAppear { stats.refresh() }
            .onChange(of: activity.isPreparing) { _, _ in stats.refresh() }
        }
    }

    private var statusHeader: some View {
        let pending = stats.phoneOnly + (stats.counts[.uploading] ?? 0) + (stats.counts[.queued] ?? 0)
        let upToDate = pending == 0 && !activity.isPreparing
        return HStack(spacing: 14) {
            Image(systemName: upToDate ? "checkmark.icloud.fill" : "icloud.and.arrow.up")
                .font(.system(size: 40))
                .foregroundStyle(upToDate ? .green : .blue)
                .symbolEffect(.pulse, isActive: activity.isPreparing)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(upToDate ? "Backup is up to date" : "\(pending) item(s) to back up").font(.headline)
                Text(chatTitle.isEmpty ? "Telegram" : "To \(chatTitle)").font(.subheadline).foregroundStyle(.secondary)
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

/// Files the Bot API can't fully handle. Never presented as backed up when they aren't.
struct LargeFilesView: View {
    @State private var tooLarge: [LibraryItem] = []
    @State private var uploadOnly: [LibraryItem] = []

    var body: some View {
        List {
            Section {
                Text("Telegram bots can upload files up to 50 MB and download files up to 20 MB. Version 2 will log in as your own Telegram account to lift these limits (up to 2 GB, or 4 GB with Premium).")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                if tooLarge.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(tooLarge) { LargeFileRow(item: $0) }
            } header: {
                Text("Not backed up: over 50 MB (\(tooLarge.count))")
            } footer: {
                Text("These are NOT backed up. Keep them on your phone or back them up another way until version 2.")
            }
            Section {
                if uploadOnly.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(uploadOnly) { LargeFileRow(item: $0) }
            } header: {
                Text("Backed up, but over 20 MB (\(uploadOnly.count))")
            } footer: {
                Text("These are in your Telegram channel and can be opened there, but the app can't download or verify them yet, so they are never offered in Free Up Space.")
            }
        }
        .navigationTitle("Needs version 2")
        .onAppear(perform: load)
    }

    private func load() {
        let store = AppEnvironment.shared.store
        tooLarge = (try? store.items(status: .tooLarge)) ?? []
        uploadOnly = ((try? store.items(status: .backedUp)) ?? []).filter { $0.sizeClass == .uploadOnly }
    }
}

private struct LargeFileRow: View {
    let item: LibraryItem
    @State private var image: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let image { Image(uiImage: image).resizable().scaledToFill() } else { Color(.secondarySystemBackground) }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading) {
                Text(item.filename).lineLimit(1)
                Text("\(Format.bytes(item.fileSize + (item.pairedVideoSize ?? 0))) · \(Format.date(item.creationDate, style: .medium, time: .none))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task {
            let env = AppEnvironment.shared
            if let id = item.localIdentifier, let asset = env.photos.asset(localIdentifier: id) {
                image = await env.photos.image(for: asset, targetSize: CGSize(width: 120, height: 120))
            } else if item.thumbnail != nil {
                image = try? await env.media.thumbnail(for: item)
            }
        }
    }
}
