import SwiftUI
import Photos
import LelvoCore

@MainActor
final class BackupStatsModel: ObservableObject {
    @Published var backedUp = 0
    @Published var pending = 0
    @Published var failed = 0
    @Published var cloudOnly = 0
    @Published var onDevice = 0
    @Published var notQueued = 0
    /// Everything "Back Up Now" would upload.
    @Published var left = 0
    /// Failed items a retry can help.
    @Published var retryable = 0
    /// Photos here that the user deleted from the backup.
    @Published var removedFromBackup = 0
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
            // Photos deleted in the Photos app while queued would otherwise count as left to back up.
            env.engine.dropDeletedQueuedItems()
            let counts = (try? env.store.counts()) ?? [:]
            let queued = ((try? env.store.items(status: .queued)) ?? []) + ((try? env.store.items(status: .uploading)) ?? [])
            let failedItems = (try? env.store.items(status: .failed)) ?? []
            let autoBackup = Prefs.autoBackup
            let all = (try? env.store.items(status: .backedUp)) ?? []
            var onDevice = 0, cloudOnly = 0, removed = 0
            var work: BackupCounts
            if DemoMode.isActive {
                // App Review demo: the sample items waiting for "Back up now" stand in for this iPhone's photos.
                work = BackupCounts.compute(queued: queued, failed: failedItems, candidates: [], known: [], offBackup: [], autoBackup: autoBackup)
                work.notQueued = DemoMode.pendingItems().count
                onDevice = work.notQueued
                cloudOnly = all.count
            } else if PhotoLibraryService.hasAccess {
                let assets = env.photos.fetchAllAssets()
                onDevice = assets.count
                work = BackupCounts.compute(queued: queued, failed: failedItems, candidates: env.photos.backupCandidates().map(\.localIdentifier),
                                            known: (try? env.store.knownLocalIdentifiers()) ?? [],
                                            offBackup: (try? env.store.offBackupLocalIdentifiers()) ?? [], autoBackup: autoBackup)
                let present = env.photos.existingIdentifiers(all.compactMap(\.localIdentifier))
                cloudOnly = all.filter { $0.localIdentifier.map { !present.contains($0) } ?? true }.count
                removed = RemovedFromBackupModel.photos().count
            } else {
                work = BackupCounts.compute(queued: queued, failed: failedItems, candidates: [], known: [], offBackup: [], autoBackup: autoBackup)
                cloudOnly = all.count
            }
            let (onDeviceCount, cloudOnlyCount, removedCount, result) = (onDevice, cloudOnly, removed, work)
            await MainActor.run {
                self.backedUp = counts[.backedUp] ?? 0
                self.pending = result.pending(autoBackup: autoBackup)
                self.failed = result.failed
                self.retryable = result.retryable
                self.cloudOnly = cloudOnlyCount
                self.onDevice = onDeviceCount
                self.notQueued = result.notQueued
                self.left = result.left
                self.removedFromBackup = removedCount
            }
        }
    }
}

struct BackupDashboardView: View {
    @EnvironmentObject private var activity: BackupActivity
    @EnvironmentObject private var app: AppModel
    @StateObject private var stats = BackupStatsModel()
    @State private var runJustEnded = false
    @AppStorage(Prefs.Key.wifiOnly) private var wifiOnly = true
    @AppStorage(Prefs.Key.chargingOnly) private var chargingOnly = false
    @AppStorage(Prefs.Key.backupPaused) private var paused = false
    @AppStorage(Prefs.Key.keepAwakeDuringBackup) private var keepAwake = true
    @AppStorage(Prefs.Key.autoBackup) private var autoBackup = false
    @AppStorage(Prefs.Key.autoBackupAsked) private var autoBackupAsked = false
    @AppStorage(Prefs.Key.firstFullBackupAt) private var firstFullBackupAt: Double = 0
    private var firstFullBackupDone: Bool { firstFullBackupAt > 0 }
    @State private var showAutomationGuide = false

    /// The first time nothing is left to send, so the Camera automation is offered when they trust Lelvo.
    private func markFirstFullBackup() {
        guard firstFullBackupAt == 0, stats.backedUp > 0, stats.pending == 0, stats.notQueued == 0 else { return }
        firstFullBackupAt = Date().timeIntervalSince1970
    }

    /// Asked once, for people who finished setup before automatic backup was offered there.
    private var autoBackupCard: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label("Back up new photos automatically", systemImage: "arrow.triangle.2.circlepath")
                    .font(.headline)
                Text("Lelvo can back up new photos when you open it, in the background and overnight.")
                    .font(.subheadline).foregroundStyle(.secondary)
                HStack {
                    Button("Turn on") {
                        autoBackup = true
                        autoBackupAsked = true
                        Haptics.success()
                        ToastCenter.shared.show(.info, "Automatic backup is on")
                        ContinuedBackup.start(everything: true)
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                    Button("Not now") { autoBackupAsked = true }
                        .buttonStyle(.bordered)
                }
            }
            .padding(.vertical, 4)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if !autoBackup, !autoBackupAsked { autoBackupCard }
                #if os(iOS)
                AutomationOfferCard(firstFullBackupDone: firstFullBackupDone, showGuide: $showAutomationGuide)
                #endif
                Section {
                    statusHeader
                    if activity.isRunning {
                        Button(role: .destructive) {
                            AppEnvironment.shared.engine.pause()
                            ToastCenter.shared.show(.info, "Pausing the backup")
                        } label: {
                            Label("Pause backup", systemImage: "pause.circle.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .listRowSeparator(.hidden)
                    } else if activity.isStarting {
                        Button {} label: {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Starting backup…")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(true)
                        .listRowSeparator(.hidden)
                    } else if stats.pending > 0 || stats.notQueued > 0 {
                        Button {
                            Haptics.start()
                            ContinuedBackup.start(everything: true)
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
                    } else if stats.retryable > 0 {
                        Button {
                            Haptics.start()
                            ToastCenter.shared.show(.info, "Retrying \(stats.retryable) failed")
                            Task {
                                await Task.detached { AppEnvironment.shared.engine.retryFailed() }.value
                                ContinuedBackup.start()
                            }
                        } label: {
                            Label("Retry \(stats.retryable) failed", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .listRowSeparator(.hidden)
                    }
                    if activity.isRunning && activity.total > 0 {
                        ProgressView(value: Double(activity.done), total: Double(max(activity.total, 1))) {
                            Text("\(activity.done) of \(activity.total) done · \(activity.remaining) left")
                                .font(.subheadline.monospacedDigit())
                                .contentTransition(.numericText())
                                .motion(Motion.standard, value: activity.done)
                        }
                        if let notice = activity.notice {
                            Label(notice, systemImage: "hourglass").font(.caption).foregroundStyle(.orange)
                        }
                        if activity.failed > 0 {
                            Text("\(activity.failed) failed in this run (see Failed below)").font(.caption).foregroundStyle(.red)
                        }
                        ForEach(activity.lanes.sorted(by: { $0.key < $1.key }), id: \.key) { key, lane in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: "arrow.up.circle").foregroundStyle(.tint)
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
                                    // Only for a file that takes a while, where the bar alone looks stuck.
                                    if let left = activity.secondsLeft[key], left >= 20 {
                                        Text(Format.timeLeft(left)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    }
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
                    }
                }

                #if os(iOS)
                // Its own row, like a switch in Settings (squeezed into the status card it overflowed the card).
                Section {
                    Toggle("Keep iPhone awake while backing up", isOn: $keepAwake)
                } footer: {
                    Text(keepAwake
                         ? "While a backup runs and Lelvo is open, your iPhone won't lock. It locks as usual once the backup is done.\n\nTip: for a big backup, start it at night with your iPhone charging and Lelvo open. It locks on its own when the backup is done."
                         : "Your iPhone may lock and pause a backup; open Lelvo to continue.")
                }
                #endif

                if PhotoLibraryService.authorizationStatus == .limited {
                    Section {
                        Label("Limited photo access: only photos you selected are backed up.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Button("Allow full access in Settings") {
                            PlatformActions.openPhotoSettings()
                        }
                    }
                }

                Section("Library") {
                    statRow("On this \(Device.name)", stats.onDevice, Device.symbol, .secondary)
                    statRow("Backed up (verified)", stats.backedUp, BackupBadge.backedUp.symbol, BackupBadge.backedUp.tint)
                    statRow("Only in the cloud", stats.cloudOnly, BackupBadge.cloudOnly.symbol, BackupBadge.cloudOnly.tint)
                    statRow("Waiting to upload", stats.pending, BackupBadge.waiting.symbol, .secondary)
                    NavigationLink { FailedItemsView() } label: {
                        statRow("Failed", stats.failed, "exclamationmark.icloud.fill", stats.failed > 0 ? .red : .secondary)
                    }
                    if stats.removedFromBackup > 0 {
                        NavigationLink { RemovedFromBackupView() } label: {
                            statRow("Removed from backup", stats.removedFromBackup, "icloud.slash", .secondary)
                        }
                    }
                }

                Section("Tools") {
                    NavigationLink { FreeUpSpaceView() } label: { Label("Free up space", systemImage: "internaldrive") }
                    NavigationLink { SaveAllToPhotosView() } label: { Label("Save all to Photos", systemImage: "square.and.arrow.down.on.square") }
                    NavigationLink { TakeoutGuideView(source: .photos) } label: { Label("Import from Google Photos", systemImage: "photo.stack") }
                    NavigationLink { TakeoutGuideView(source: .drive) } label: { Label("Import from Google Drive", systemImage: "folder") }
                    #if os(iOS)
                    NavigationLink { AutomaticBackupExplainerView() } label: { Label("Automatic backup on iPhone", systemImage: "bolt.badge.clock") }
                    #endif
                    Button {
                        Task {
                            await LibraryRescan.run()
                            stats.refresh()
                        }
                    } label: { Label("Re-scan the Telegram library", systemImage: "arrow.triangle.2.circlepath") }
                }
            }
            .navigationTitle("Backup")
            #if os(iOS)
            .settingsButton()
            #endif
            .navigationDestination(isPresented: $app.showFreeUpSpace) { FreeUpSpaceView() }
            #if os(iOS)
            .navigationDestination(isPresented: $showAutomationGuide) { AutomaticBackupExplainerView() }
            #endif
            .refreshable { stats.refresh() }
            .onAppear { stats.refresh() }
            .onChange(of: stats.pending) { _, _ in markFirstFullBackup() }
            .onChange(of: stats.notQueued) { _, _ in markFirstFullBackup() }
            .onChange(of: stats.backedUp) { _, _ in markFirstFullBackup() }
            .onChange(of: activity.isRunning) { _, _ in stats.refresh() }
            // One success haptic when a run ends with everything safe, not for each photo.
            // The counts refresh just after the run ends, so .running → .pending → .complete is still one finished run.
            .onChange(of: headerState) { old, new in
                if old == .running { runJustEnded = true }
                if new == .complete && runJustEnded { Haptics.success() }
                if new != .running && new != .pending { runJustEnded = false }
            }
        }
    }

    private enum HeaderState { case running, complete, completeWithFailures, pending, notBackedUp }

    private var headerState: HeaderState {
        if activity.isRunning { return .running }
        if stats.pending > 0 { return .pending }
        if stats.notQueued > 0 { return .notBackedUp }
        return stats.failed > 0 ? .completeWithFailures : .complete
    }

    /// Mirrors Google Photos: "Backup complete" when nothing is left, failures called out separately.
    private var statusHeader: some View {
        // A run that is still listing its photos has no total yet: the photos it's about to queue count, not "0 left".
        let left = activity.isRunning
            ? (activity.total > 0 ? activity.remaining : max(stats.pending, stats.notQueued))
            : stats.pending
        let state = headerState
        let icon: String, tint: Color, title: String
        switch state {
        case .complete:
            (icon, tint, title) = ("checkmark.icloud.fill", .green, "Backup complete")
        case .completeWithFailures:
            (icon, tint, title) = ("exclamationmark.icloud.fill", .orange,
                                   "Backup complete, \(stats.failed) item\(stats.failed == 1 ? "" : "s") couldn't be backed up")
        case .running, .pending:
            (icon, tint, title) = ("icloud.and.arrow.up", .accentColor, "\(left) item\(left == 1 ? "" : "s") left to back up")
        case .notBackedUp:
            (icon, tint, title) = ("icloud.slash", .secondary,
                                   "\(stats.notQueued) item\(stats.notQueued == 1 ? "" : "s") not in the cloud")
        }
        let mark: CatchingMark.Status = switch state {
        case .complete: .complete
        case .completeWithFailures: .attention
        case .running: .working
        case .pending, .notBackedUp: .idle
        }
        return VStack(spacing: 10) {
            CatchingMark(status: mark)
                .padding(.top, 8)
                .padding(.bottom, 4)
            Label {
                Text(title).font(.headline).multilineTextAlignment(.center)
                    .contentTransition(.numericText())
            } icon: {
                if state == .completeWithFailures || state == .notBackedUp {
                    Image(systemName: icon).foregroundStyle(tint)
                }
            }
            Text(state == .complete ? "Everything\(stats.removedFromBackup > 0 ? " else" : "") on this \(Device.name) is backed up"
                 : state == .notBackedUp ? "Back up now uploads them all, or choose photos in Photos and tap Back up."
                 : "To your Telegram library")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let last = UserDefaults.standard.object(forKey: Prefs.Key.lastBackupAt) as? Date {
                Text("Last upload \(Format.relative(last))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .motion(Motion.standard, value: title)
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
    @State private var confirmingStranded = false
    @State private var alert: GalleryAlert?

    private var stranded: [MediaItem] { items.filter(\.isStrandedInCloud) }

    var body: some View {
        Form {
            if !items.isEmpty {
                if stranded.count < items.count {
                    Section {
                        Button {
                            Task {
                                await Task.detached { AppEnvironment.shared.engine.retryFailed() }.value
                                await load()
                                ContinuedBackup.start()
                            }
                        } label: { Label("Retry all failed", systemImage: "arrow.clockwise") }
                    }
                }
                if !stranded.isEmpty {
                    Section {
                        Button(role: .destructive) { confirmingStranded = true } label: {
                            Label("Move \(stranded.count) to Recently Deleted", systemImage: "trash")
                        }
                    } footer: {
                        Text("Part of \(stranded.count == 1 ? "this item is" : "these items are") missing from your Telegram library, and \(stranded.count == 1 ? "it isn't" : "they aren't") on this \(Device.name). Back up from the device that has \(stranded.count == 1 ? "it" : "them"), or delete what's left.")
                    }
                }
                Section("\(items.count) failed") {
                    ForEach(items) { item in
                        HStack(spacing: 12) {
                            FailedThumbnail(localIdentifier: item.localIdentifier)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.filename).lineLimit(1)
                                Text(item.isStrandedInCloud ? "Incomplete in your Telegram library" : item.lastError ?? "Unknown error").font(.caption).foregroundStyle(.red)
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
                                } label: { Label("Delete from \(Device.name)", systemImage: "trash") }
                            }
                        }
                    }
                }
            }
        }
        .platformGroupedForm()
        .overlay {
            if items.isEmpty {
                EmptyStateView(systemImage: "checkmark.icloud", title: "Nothing Failed", message: "Every attempted upload went through.")
            }
        }
        .navigationTitle("Failed Uploads")
        .task { await load() }
        .confirmationDialog("Move \(stranded.count) incomplete item\(stranded.count == 1 ? "" : "s") to Recently Deleted?", isPresented: $confirmingStranded, titleVisibility: .visible) {
            Button("Move to Recently Deleted", role: .destructive) {
                let targets = stranded
                Task {
                    do { try await GalleryActions.deleteFromCloud(targets) } catch {
                        alert = GalleryAlert(title: "Couldn't delete", message: error.localizedDescription)
                    }
                    await load()
                }
            }
        } message: {
            Text("What's left of them stays there for 30 days, then it's deleted from your Telegram library.")
        }
        .alert(item: $alert) { Alert(title: Text($0.title), message: Text($0.message)) }
    }

    /// Off the main thread: the store can be busy with upload checkpoints.
    private func load() async {
        items = await Task.detached { (try? AppEnvironment.shared.store.items(status: .failed)) ?? [] }.value
    }
}

struct FailedThumbnail: View {
    let localIdentifier: String?
    @State private var image: PlatformImage?

    var body: some View {
        Color.tileBackground
            .frame(width: 52, height: 52)
            .overlay { if let image { Image(platformImage: image).resizable().scaledToFill() } }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .task(id: localIdentifier) {
                guard let localIdentifier else { return }
                // The PhotoKit lookup off the main actor: a long Failed list asks for one per row while scrolling.
                image = await Task.detached(priority: .userInitiated) {
                    let photos = AppEnvironment.shared.photos
                    guard let asset = photos.asset(localIdentifier: localIdentifier) else { return nil }
                    return await photos.image(for: asset, targetSize: CGSize(width: 156, height: 156))
                }.value
            }
    }
}

/// Review duplicates: extra copies in Telegram (same upload twice, or the same content as two items)
/// and identical photos on this iPhone. Nothing is removed without a tap; the first copy always stays.
struct DuplicatesView: View {
    @State private var messageDuplicates: [Int64] = []
    @State private var cloudGroups: [BackupEngine.CloudDuplicateGroup] = []
    @State private var phoneGroups: [BackupEngine.PhoneDuplicateGroup] = []
    @State private var selectedCopies = Set<String>()
    @State private var loading = true
    @State private var busy: String?
    @State private var alert: GalleryAlert?
    @State private var confirmCloud = false
    @State private var similar: [SimilarPhotosService.Group] = []
    @State private var similarProgress: (done: Int, total: Int)?
    @State private var selectedSimilar = Set<String>()
    @State private var confirmSimilar = false
    private var env: AppEnvironment { AppEnvironment.shared }

    var body: some View {
        Form {

            if !messageDuplicates.isEmpty || !cloudGroups.isEmpty {
                Section {
                    if !messageDuplicates.isEmpty {
                        Label("\(messageDuplicates.count) extra upload\(messageDuplicates.count == 1 ? "" : "s") of files that are already stored",
                              systemImage: "doc.on.doc")
                    }
                    ForEach(cloudGroups) { g in
                        HStack(spacing: 12) {
                            DuplicateThumb(item: g.keep, localIdentifier: g.keep.localIdentifier)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(g.keep.filename).lineLimit(1)
                                Text("Stored \(g.extras.count + 1) times · \(Format.bytes(g.wastedBytes)) extra")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button(role: .destructive) { confirmCloud = true } label: {
                        Label("Remove extra copies from Telegram", systemImage: "trash")
                    }
                } header: { Text("In your Telegram library") } footer: {
                    Text("One copy of each always stays, and photos on this \(Device.name) stay linked to it.")
                }
            }

            if !phoneGroups.isEmpty {
                Section {
                    ForEach(phoneGroups) { g in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(g.item.filename).font(.subheadline.weight(.semibold)).lineLimit(1)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    if let original = g.original {
                                        DuplicateThumb(item: g.item, localIdentifier: original, size: 72)
                                            .overlay(alignment: .bottomLeading) {
                                                Text("Kept").font(.caption2.bold()).padding(4).background(.black.opacity(0.6), in: Capsule()).padding(4)
                                            }
                                    }
                                    ForEach(g.copies, id: \.self) { copy in
                                        let selected = selectedCopies.contains(copy)
                                        DuplicateThumb(item: g.item, localIdentifier: copy, size: 72)
                                            .overlay(alignment: .topTrailing) {
                                                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                                    .foregroundStyle(selected ? Color.accentColor : .white).padding(4)
                                            }
                                            .onTapGesture {
                                                if selected { selectedCopies.remove(copy) } else { selectedCopies.insert(copy) }
                                            }
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    HStack {
                        Button("Select all copies") { selectedCopies = Set(phoneGroups.flatMap(\.copies)) }
                        Spacer()
                        Button(role: .destructive) { deletePhoneCopies() } label: { Text("Delete \(selectedCopies.count) from \(Device.name)") }
                            .disabled(selectedCopies.isEmpty)
                    }
                    .buttonStyle(.borderless)
                } header: { Text("On this \(Device.name)") } footer: {
                    Text("Identical copies of photos that are already backed up. Deleting a copy moves it to Recently Deleted; the backup isn't affected.")
                }
            }

            similarSection
        }
        .platformGroupedForm()
        .overlay {
            if loading {
                ProgressView("Looking for duplicates…")
            } else if messageDuplicates.isEmpty && cloudGroups.isEmpty && phoneGroups.isEmpty && similar.isEmpty && similarProgress == nil {
                EmptyStateView(systemImage: "checkmark.circle", title: "No Duplicates",
                               message: "Nothing is stored twice in your library or on this \(Device.name).")
            }
        }
        .navigationTitle("Duplicates")
        .disabled(busy != nil)
        .overlay {
            if let busy { ProgressView(busy).padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) }
        }
        .task { await load() }
        .task { await findSimilar() }
        .refreshable { await load(); await findSimilar() }
        .alert(item: $alert) { a in Alert(title: Text(a.title), message: Text(a.message)) }
        .alert("Delete \(selectedSimilar.count) similar photos?", isPresented: $confirmSimilar) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { deleteSimilar() }
        } message: {
            let chosen = similar.flatMap(\.entries).filter { selectedSimilar.contains($0.id) }
            let unsafe = chosen.filter { $0.asset != nil && $0.item?.status != .backedUp }.count
            Text(unsafe > 0
                 ? "\(unsafe) of these are not backed up yet and are lost once Recently Deleted in Photos is emptied."
                 : "Photos on this \(Device.name) go to Recently Deleted in Photos; photos only in your Telegram library go to Recently Deleted in Lelvo.")
        }
        .alert("Remove extra copies?", isPresented: $confirmCloud) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { removeCloud() }
        } message: {
            Text("Deletes only the duplicate messages. One copy of every photo and video stays in your library.")
        }
    }

    private func load() async {
        loading = true
        let env = self.env
        let (m, c, p) = await Task.detached {
            (env.library.duplicateMessageIds, env.engine.cloudDuplicateGroups(), env.engine.phoneDuplicateGroups())
        }.value
        messageDuplicates = m
        cloudGroups = c
        phoneGroups = p
        selectedCopies = selectedCopies.intersection(Set(p.flatMap(\.copies)))
        loading = false
    }

    // MARK: - Similar photos (#15)

    @ViewBuilder private var similarSection: some View {
        if let p = similarProgress {
            Section("Similar Photos") {
                ProgressView(value: Double(p.done), total: Double(max(p.total, 1))) {
                    Text("Comparing photos taken close together…")
                } currentValueLabel: {
                    Text("\(p.done) of \(p.total)")
                }
            }
        } else if !similar.isEmpty {
            Section {
                ForEach(similar) { g in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 8) {
                            ForEach(g.entries, id: \.id) { entry in similarTile(entry, isBest: entry.id == g.best) }
                        }
                        .padding(.vertical, 4)
                    }
                }
                HStack {
                    // Photos not backed up are never chosen for you: select them one by one if you mean it.
                    Button("Select extras to delete") {
                        selectedSimilar = Set(similar.flatMap { g in
                            g.entries.filter { $0.id != g.best && !(($0.asset != nil) && $0.item?.status != .backedUp) }.map(\.id)
                        })
                    }
                    Spacer()
                    Button(role: .destructive) { confirmSimilar = true } label: { Text("Delete \(selectedSimilar.count)") }
                        .disabled(selectedSimilar.isEmpty)
                }
                .buttonStyle(.borderless)
            } header: { Text("Similar Photos") } footer: {
                Text("Photos taken moments apart that look almost the same. The suggested one to keep is marked Best. Photos on this \(Device.name) go to Recently Deleted in Photos; photos only in your Telegram library go to Recently Deleted in Lelvo.")
            }
        }
    }

    private func similarTile(_ entry: GalleryEntry, isBest: Bool) -> some View {
        let id = entry.id
        let selected = selectedSimilar.contains(id)
        let notBackedUp = entry.asset != nil && entry.item?.status != .backedUp
        return SimilarThumb(entry: entry)
            .overlay(alignment: .topTrailing) {
                // A selected photo here is one to delete, so it says so: a tick next to "Best" read as "keep these".
                Image(systemName: selected ? "trash.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.red : .white).padding(4)
            }
            .overlay(alignment: .bottomLeading) {
                if isBest {
                    Text("Best").font(.caption2.bold()).padding(4).background(.black.opacity(0.6), in: Capsule()).padding(4).foregroundStyle(.white)
                } else if notBackedUp {
                    Image(systemName: "icloud.slash").font(.caption2.bold()).padding(4).background(.black.opacity(0.6), in: Capsule())
                        .padding(4).foregroundStyle(.white)
                } else if entry.asset == nil {
                    Image(systemName: "icloud").font(.caption2.bold()).padding(4).background(.black.opacity(0.6), in: Capsule())
                        .padding(4).foregroundStyle(.white)
                }
            }
            .onTapGesture { if selected { selectedSimilar.remove(id) } else { selectedSimilar.insert(id) } }
            .accessibilityValue(selected ? "Will be deleted" : "")
            .accessibilityLabel("\(isBest ? "Best photo" : "Photo")\(notBackedUp ? ", not backed up" : "")\(entry.asset == nil ? ", only in the cloud" : "")\(selected ? ", selected" : "")")
            .accessibilityAddTraits(.isButton)
    }

    private func findSimilar() async {
        guard similarProgress == nil else { return }
        similarProgress = (0, 0)
        // Runs in the view's task, so leaving Duplicates stops the comparing.
        let found = await env.similar.find { done, total in Task { @MainActor in if similarProgress != nil { similarProgress = (done, total) } } }
        similarProgress = nil
        guard !Task.isCancelled else { return }
        similar = found
        selectedSimilar = selectedSimilar.intersection(Set(similar.flatMap { $0.entries.map(\.id) }))
    }

    private func deleteSimilar() {
        let chosen = similar.flatMap(\.entries).filter { selectedSimilar.contains($0.id) }
        let onDevice = chosen.compactMap(\.asset).map(\.localIdentifier)
        let cloudOnly = chosen.filter { $0.asset == nil }.compactMap(\.item)
        Task {
            do {
                // Photos asks to confirm too and keeps them in its Recently Deleted.
                if !onDevice.isEmpty { try await env.photos.deleteAssets(onDevice) }
                if !cloudOnly.isEmpty { try await GalleryActions.deleteFromCloud(cloudOnly) }
                Haptics.success()
                appLog("Deleted \(onDevice.count) similar photos from this \(Device.name) and moved \(cloudOnly.count) to Recently Deleted")
                selectedSimilar.removeAll()
            } catch let error as NSError where error.domain == PHPhotosErrorDomain && error.code == PHPhotosError.userCancelled.rawValue {
                // The user said no to Photos' own confirmation.
            } catch {
                AppLog.shared.error("Deleting similar photos failed: \(error.localizedDescription)")
                alert = GalleryAlert(title: "Couldn't delete", message: error.localizedDescription)
            }
            await findSimilar()
        }
    }

    private func removeCloud() {
        Task {
            busy = "Removing extra copies…"
            defer { busy = nil }
            do {
                if !messageDuplicates.isEmpty { try await env.library.removeDuplicateMessages() }
                let n = try await env.engine.removeCloudDuplicates(cloudGroups)
                Haptics.success()
                alert = GalleryAlert(title: "Done", message: "Removed \(n + messageDuplicates.count) extra copies.")
            } catch {
                alert = GalleryAlert(title: "Couldn't remove", message: error.localizedDescription)
            }
            await load()
        }
    }

    private func deletePhoneCopies() {
        let ids = Array(selectedCopies)
        Task {
            do {
                let n = try await env.engine.deletePhoneCopies(ids)
                if n > 0 { Haptics.success() }
                selectedCopies.removeAll()
            } catch {
                // The user cancelled iOS's confirmation.
            }
            await load()
        }
    }
}

private struct SimilarThumb: View {
    let entry: GalleryEntry
    @State private var image: PlatformImage?

    var body: some View {
        Color.tileBackground
            .frame(width: 88, height: 88)
            .overlay { if let image { Image(platformImage: image).resizable().scaledToFill() } }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .task(id: entry.id) {
                for await img in ThumbnailPipeline.shared.images(for: entry, pixels: 264) { image = img }
            }
    }
}

private struct DuplicateThumb: View {
    let item: MediaItem
    let localIdentifier: String?
    var size: CGFloat = 52
    @State private var image: PlatformImage?

    var body: some View {
        Color.tileBackground
            .frame(width: size, height: size)
            .overlay { if let image { Image(platformImage: image).resizable().scaledToFill() } }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .task(id: localIdentifier ?? item.id) {
                let env = AppEnvironment.shared
                let pixels = size * 3
                // The PhotoKit lookup off the main actor, as in FailedThumbnail.
                let local: PlatformImage? = await Task.detached(priority: .userInitiated) {
                    guard let id = localIdentifier, let asset = env.photos.asset(localIdentifier: id) else { return nil }
                    return await env.photos.image(for: asset, targetSize: CGSize(width: pixels, height: pixels))
                }.value
                if let local { image = local } else { image = try? await env.media.thumbnail(for: item) }
            }
    }
}
