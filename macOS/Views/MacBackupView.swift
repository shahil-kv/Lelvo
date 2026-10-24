import SwiftUI
import CloudGalleryCore

/// Backup page in the style of System Settings (iCloud, Time Machine): solid grouped sections, the status and
/// its one action on top, live uploads, library numbers, options inline, then tools.
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
    @Environment(\.openWindow) private var openWindow
    @State private var debugPage: String?

    var body: some View {
        Form {
            Section { statusRow } footer: { statusFooter }

            if activity.isRunning && !activity.lanes.isEmpty {
                Section("Uploading Now") {
                    ForEach(activity.lanes.sorted(by: { $0.key < $1.key }), id: \.key) { _, lane in laneRow(lane) }
                }
            }

            Section {
                countRow("On This Mac", stats.onDevice, Device.symbol, .gray) { navigation.selection = .library }
                countRow("Backed Up", stats.backedUp, "checkmark.icloud.fill", .green) { navigation.selection = .library }
                countRow("Only in Cloud", stats.cloudOnly, "icloud.fill", .cyan) { navigation.selection = .cloudOnly }
                countRow("Not Backed Up", stats.notQueued + stats.pending, "icloud.slash.fill", .orange) { navigation.selection = .notBackedUp }
                NavigationLink {
                    FailedItemsView()
                } label: {
                    iconLabel("Failed", "exclamationmark.icloud.fill", stats.failed > 0 ? .red : .gray, value: stats.failed)
                }
            } header: { Text("Library") } footer: {
                Button("What the icons on photos mean") { openWindow(id: MacNavigation.legendWindowId) }
                    .buttonStyle(.link)
            }

            Section {
                Toggle(isOn: $autoBackup) { iconLabel("Back Up Automatically", "arrow.triangle.2.circlepath", .blue) }
                Toggle(isOn: $wifiOnly) { iconLabel("Wi-Fi Only", "wifi", .blue) }
                Toggle(isOn: $chargingOnly) { iconLabel("Only on Power Adapter", "powerplug.fill", .green) }
            } header: { Text("Options") } footer: {
                Text(autoBackup ? "While CloudGallery is open, even with its window closed, new photos are backed up every hour."
                                : "Nothing uploads on its own. Use Back Up Now, or select photos and choose Back Up.")
            }

            Section("Tools") {
                NavigationLink { FreeUpSpaceView() } label: { iconLabel("Free Up Space", "internaldrive.fill", .blue) }
                NavigationLink { DuplicatesView() } label: { iconLabel("Duplicates", "square.on.square.fill", .purple) }
                Button { rescan() } label: {
                    HStack {
                        iconLabel("Re-scan Telegram Library", "arrow.clockwise", .teal)
                        Spacer()
                        if rescanning { ProgressView().controlSize(.small) }
                        else if let rescanResult { Text(rescanResult).foregroundStyle(.secondary) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(rescanning)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Backup")
        .navigationSubtitle("To your Telegram library")
        .onAppear { stats.refresh() }
        #if DEBUG
        .navigationDestination(item: $debugPage) { page in
            switch page {
            case "failed": FailedItemsView()
            case "duplicates": DuplicatesView()
            default: FreeUpSpaceView()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .debugPush)) { debugPage = $0.object as? String }
        #endif
        .onChange(of: activity.isRunning) { _, _ in stats.refresh() }
        .animation(.snappy(duration: 0.25), value: activity.isRunning)
        .animation(.snappy(duration: 0.25), value: activity.lanes.count)
    }

    // MARK: - Status

    private enum Status { case running, complete, failures, notBackedUp }

    private var state: Status {
        if activity.isRunning { return .running }
        if stats.pending + stats.notQueued > 0 { return .notBackedUp }
        return stats.failed > 0 ? .failures : .complete
    }

    private var statusRow: some View {
        let left = activity.isRunning && activity.total > 0 ? activity.remaining : stats.pending + stats.notQueued
        let (icon, tint, title): (String, Color, String) = {
            switch state {
            case .complete: return ("checkmark.icloud.fill", .green, "Backup Complete")
            case .failures: return ("exclamationmark.icloud.fill", .orange, "\(stats.failed) Item\(stats.failed == 1 ? "" : "s") Couldn't Be Backed Up")
            case .running: return ("icloud.and.arrow.up.fill", .blue, "Backing Up \(left.formatted()) Item\(left == 1 ? "" : "s")")
            case .notBackedUp: return (paused ? "pause.circle.fill" : "icloud.slash.fill", paused ? .orange : .gray,
                                       "\(left.formatted()) Item\(left == 1 ? "" : "s") Not Backed Up")
            }
        }()
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title3.weight(.semibold)).contentTransition(.numericText())
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 12)
                action
            }
            if activity.isRunning && activity.total > 0 {
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: Double(activity.done), total: Double(max(activity.total, 1)))
                    HStack {
                        Text("\(activity.done.formatted()) of \(activity.total.formatted())")
                        if activity.failed > 0 { Text("· \(activity.failed) failed").foregroundStyle(.red) }
                        Spacer()
                        Text("\(activity.remaining.formatted()) left")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
        }
        .padding(.vertical, 6)
    }

    private var subtitle: String {
        switch state {
        case .running: return activity.notice ?? activity.message ?? "Uploading originals to your Telegram library."
        case .complete: return "Everything in Photos on this Mac is in your Telegram library."
        case .failures: return "Everything else is safe. Retry, or open Failed to see why."
        case .notBackedUp: return paused ? "Paused. Automatic backups wait until you resume." : "Back Up Now uploads them all."
        }
    }

    @ViewBuilder private var statusFooter: some View {
        if let last = UserDefaults.standard.object(forKey: Prefs.Key.lastBackupAt) as? Date {
            Text("Last upload \(Format.relative(last)).")
        }
    }

    @ViewBuilder private var action: some View {
        if activity.isRunning {
            Button("Pause") { AppEnvironment.shared.engine.pause() }
                .controlSize(.large)
        } else if stats.pending + stats.notQueued > 0 {
            Button(paused ? "Resume" : "Back Up Now") { ContinuedBackup.start(everything: true) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("b", modifiers: .command)
        } else if stats.failed > 0 {
            Button("Retry") {
                Task {
                    await Task.detached { AppEnvironment.shared.engine.retryFailed() }.value
                    ContinuedBackup.start()
                }
            }
            .controlSize(.large)
        }
    }

    // MARK: - Rows

    private func laneRow(_ lane: BackupActivity.LaneProgress) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(lane.name).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(lane.total > 0 ? "\(Format.bytes(lane.sent)) of \(Format.bytes(lane.total))" : "Preparing…")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: lane.total > 0 ? Double(lane.sent) : 0, total: Double(max(lane.total, 1)))
                .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private func countRow(_ title: String, _ value: Int, _ symbol: String, _ tint: Color, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack {
                iconLabel(title, symbol, tint, value: value)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// System Settings row: white glyph on a coloured rounded square, title, optional trailing value.
    private func iconLabel(_ title: String, _ symbol: String, _ tint: Color, value: Int? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(title)
            if let value {
                Spacer()
                Text(value.formatted()).monospacedDigit().foregroundStyle(.secondary).contentTransition(.numericText())
            }
        }
    }

    private func rescan() {
        rescanning = true
        rescanResult = nil
        Task {
            do {
                let s = try await AppEnvironment.shared.library.scan(full: true)
                _ = await Task.detached { AppEnvironment.shared.engine.relinkRestoredItems() }.value
                rescanResult = "\(s.items.formatted()) items"
            } catch {
                rescanResult = "Couldn't re-scan"
            }
            stats.refresh()
            rescanning = false
        }
    }
}
