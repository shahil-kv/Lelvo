import SwiftUI
import CloudGalleryCore

/// Backup page: one status card with the main action, live upload progress, library numbers and tools.
struct MacBackupView: View {
    @EnvironmentObject private var activity: BackupActivity
    @EnvironmentObject private var navigation: MacNavigation
    @StateObject private var stats = BackupStatsModel()
    @AppStorage(Prefs.Key.wifiOnly) private var wifiOnly = true
    @AppStorage(Prefs.Key.chargingOnly) private var chargingOnly = false
    @AppStorage(Prefs.Key.backupPaused) private var paused = false
    @AppStorage(Prefs.Key.autoBackup) private var autoBackup = false
    @State private var rescanning = false
    @State private var rescanResult: String?
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                statusCard
                if activity.isRunning && !activity.lanes.isEmpty { uploadsCard }
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("Library")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                        statTile("On this Mac", stats.onDevice, Device.symbol, .secondary) { navigation.selection = .library }
                        statTile("Backed up", stats.backedUp, BackupBadge.backedUp.symbol, .green) { navigation.selection = .library }
                        statTile("Only in cloud", stats.cloudOnly, BackupBadge.cloudOnly.symbol, .cyan) { navigation.selection = .cloudOnly }
                        statTile("Not backed up", stats.notQueued + stats.pending, "icloud.slash", .orange) { navigation.selection = .notBackedUp }
                        NavigationLink { FailedItemsView().formStyle(.grouped) } label: {
                            StatTileLabel(title: "Failed", value: stats.failed, symbol: "exclamationmark.icloud.fill",
                                          tint: stats.failed > 0 ? .red : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("Tools")
                    VStack(spacing: 0) {
                        NavigationLink { FreeUpSpaceView() } label: {
                            toolRow("internaldrive", .blue, "Free up space", "Remove photos from this Mac that are safely in your backup.")
                        }
                        Divider().padding(.leading, 54)
                        NavigationLink { DuplicatesView() } label: {
                            toolRow("square.on.square", .purple, "Duplicates", "Extra copies in Telegram or in Photos.")
                        }
                        Divider().padding(.leading, 54)
                        Button { rescan() } label: {
                            toolRow("arrow.triangle.2.circlepath", .teal, rescanning ? "Re-scanning…" : "Re-scan the Telegram library",
                                    rescanResult ?? "Picks up uploads made from your iPhone or another device.", busy: rescanning)
                        }
                        .disabled(rescanning)
                    }
                    .buttonStyle(.plain)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.5)))
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Backup")
        .navigationSubtitle("To your Telegram library")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { openSettings() } label: { Label("Backup Options", systemImage: "slider.horizontal.3") }
                    .help("Backup options")
            }
        }
        .onAppear { stats.refresh() }
        .onChange(of: activity.isRunning) { _, _ in stats.refresh() }
    }

    // MARK: - Status

    private enum HeaderState { case running, complete, completeWithFailures, pending, notBackedUp }

    private var headerState: HeaderState {
        if activity.isRunning { return .running }
        if stats.pending > 0 { return .pending }
        if stats.notQueued > 0 { return .notBackedUp }
        return stats.failed > 0 ? .completeWithFailures : .complete
    }

    private var statusCard: some View {
        let state = headerState
        let left = activity.isRunning && activity.total > 0 ? activity.remaining : stats.pending + stats.notQueued
        let icon: String, tint: Color, title: String, subtitle: String
        switch state {
        case .complete:
            (icon, tint, title, subtitle) = ("checkmark.icloud.fill", .green, "Backup complete", "Everything in Photos on this Mac is in your Telegram library.")
        case .completeWithFailures:
            (icon, tint, title, subtitle) = ("exclamationmark.icloud.fill", .orange,
                                             "\(stats.failed) item\(stats.failed == 1 ? "" : "s") couldn't be backed up", "Everything else is safe. Retry, or open Failed to see why.")
        case .running:
            (icon, tint, title, subtitle) = ("icloud.and.arrow.up.fill", .accentColor, "Backing up \(left.formatted()) item\(left == 1 ? "" : "s")",
                                             activity.notice ?? activity.message ?? "Uploading originals to your Telegram library.")
        case .pending, .notBackedUp:
            (icon, tint, title, subtitle) = (paused ? "pause.circle.fill" : "icloud.slash.fill", paused ? .orange : .secondary,
                                             "\(left.formatted()) item\(left == 1 ? "" : "s") not backed up",
                                             paused ? "Backup is paused. Automatic backups wait until you resume." : "Back up now uploads them all, or select photos and choose Back Up.")
        }
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 18) {
                ZStack {
                    Circle().fill(tint.opacity(0.15))
                    Image(systemName: icon)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(tint)
                        .symbolEffect(.pulse, isActive: activity.isRunning)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title2.weight(.semibold)).contentTransition(.numericText())
                    Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let last = UserDefaults.standard.object(forKey: Prefs.Key.lastBackupAt) as? Date {
                        Text("Last upload \(Format.relative(last))").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 12)
                primaryAction(state)
            }
            if activity.isRunning && activity.total > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(activity.done), total: Double(max(activity.total, 1)))
                        .tint(.accentColor)
                    HStack {
                        Text("\(activity.done.formatted()) of \(activity.total.formatted())").monospacedDigit()
                        if activity.failed > 0 { Text("· \(activity.failed) failed").foregroundStyle(.red) }
                        Spacer()
                        Text("\(activity.remaining.formatted()) left").monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 14) {
                conditionChip(autoBackup ? "Automatic" : "Manual", autoBackup ? "bolt.fill" : "hand.tap")
                if wifiOnly { conditionChip("Wi-Fi only", "wifi") }
                if chargingOnly { conditionChip("On power only", "powerplug") }
                Spacer()
                Button("Change…") { openSettings() }.buttonStyle(.link).font(.callout)
            }
        }
        .padding(22)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.separator.opacity(0.5)))
        .animation(.snappy, value: activity.isRunning)
    }

    @ViewBuilder private func primaryAction(_ state: HeaderState) -> some View {
        if activity.isRunning {
            Button { AppEnvironment.shared.engine.pause() } label: {
                Label("Pause", systemImage: "pause.fill").frame(minWidth: 90)
            }
            .controlSize(.large)
        } else if stats.pending > 0 || stats.notQueued > 0 {
            Button { ContinuedBackup.start(everything: true) } label: {
                Label(paused ? "Resume" : "Back Up Now", systemImage: "icloud.and.arrow.up.fill").frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("b", modifiers: .command)
        } else if stats.failed > 0 {
            Button {
                Task {
                    await Task.detached { AppEnvironment.shared.engine.retryFailed() }.value
                    ContinuedBackup.start()
                }
            } label: {
                Label("Retry \(stats.failed)", systemImage: "arrow.clockwise").frame(minWidth: 100)
            }
            .controlSize(.large)
        }
    }

    private var uploadsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Uploading now")
            VStack(spacing: 12) {
                ForEach(activity.lanes.sorted(by: { $0.key < $1.key }), id: \.key) { _, lane in
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.up.circle.fill").font(.title3).foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(lane.name).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(lane.total > 0 ? "\(Format.bytes(lane.sent)) of \(Format.bytes(lane.total))" : "Preparing…")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            ProgressView(value: lane.total > 0 ? Double(lane.sent) : 0, total: Double(max(lane.total, 1)))
                                .controlSize(.small)
                        }
                    }
                }
            }
            .padding(16)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.5)))
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - Pieces

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.headline).foregroundStyle(.secondary).padding(.leading, 2)
    }

    private func statTile(_ title: String, _ value: Int, _ symbol: String, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) { StatTileLabel(title: title, value: value, symbol: symbol, tint: tint) }
            .buttonStyle(.plain)
    }

    private func conditionChip(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.6), in: Capsule())
    }

    private func toolRow(_ symbol: String, _ tint: Color, _ title: String, _ detail: String, busy: Bool = false) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) } else { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    private func rescan() {
        rescanning = true
        rescanResult = nil
        Task {
            do {
                let s = try await AppEnvironment.shared.library.scan(full: true)
                await Task.detached { AppEnvironment.shared.engine.relinkRestoredItems() }.value
                rescanResult = "\(s.items.formatted()) items in your library\(s.incomplete > 0 ? ", \(s.incomplete) incomplete" : "")."
            } catch {
                rescanResult = "Couldn't re-scan: \(error.localizedDescription)"
            }
            stats.refresh()
            rescanning = false
        }
    }
}

struct StatTileLabel: View {
    let title: String
    let value: Int
    let symbol: String
    let tint: Color
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol).font(.title3).foregroundStyle(tint)
            Text(value.formatted())
                .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
            Text(title).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background.secondary.opacity(hovering ? 1 : 0.85), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(hovering ? AnyShapeStyle(tint.opacity(0.5)) : AnyShapeStyle(.separator.opacity(0.5))))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .accessibilityElement(children: .combine)
    }
}
