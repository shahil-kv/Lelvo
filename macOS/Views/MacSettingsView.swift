import SwiftUI
import LelvoCore

/// Lelvo → Settings… (⌘,): one pane per topic, like the system apps.
struct MacSettingsView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { MacGeneralSettings() }
            Tab("Backup", systemImage: "icloud.and.arrow.up") {
                NavigationStack { BackupOptionsView().formStyle(.grouped) }
            }
            Tab("Libraries", systemImage: "photo.stack") {
                NavigationStack { LibrarySettingsView() }
            }
            Tab("Memories", systemImage: "sparkles") { MemoriesSettingsView() }
            Tab("Storage", systemImage: "internaldrive") { StorageSettingsView().formStyle(.grouped) }
            Tab("Export", systemImage: "square.and.arrow.down.on.square") { ExportLibraryView().formStyle(.grouped) }
            Tab("Logs", systemImage: "doc.text.magnifyingglass") { NavigationStack { LogsView() } }
            Tab("About", systemImage: "info.circle") { NavigationStack { AboutView() } }
        }
        .frame(width: 620, height: 520)
        .disabled(!app.onboardingComplete)
    }
}

private struct MacGeneralSettings: View {
    @EnvironmentObject private var app: AppModel
    @AppStorage(Prefs.Key.autoBackup) private var autoBackup = false
    @AppStorage(MacPrefs.showMenuBarExtra) private var showMenuBarExtra = true
    @State private var accountName = "…"
    @State private var libraryName = LibraryService.titleDefault
    @State private var accountTtl: Int?
    @State private var confirmReset = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var error: String?
    private var env: AppEnvironment { AppEnvironment.shared }

    var body: some View {
        Form {
            Section("Telegram") {
                LabeledContent("Signed in as", value: accountName)
                LabeledContent("Library", value: libraryName)
                LabeledContent("Encryption", value: env.library.isEncrypted ? "End-to-end" : "Standard")
                if let days = accountTtl {
                    if days >= 730 {
                        Label("Account kept for 2 years without use", systemImage: "checkmark.shield.fill").foregroundStyle(.green)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Telegram deletes inactive accounts after \(days >= 365 ? "\(days / 365) year" : "\(days / 30) months"), and your library with them.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Button("Change to 2 years (the maximum)") {
                                Task {
                                    do { try await env.td.setAccountTtl(days: 730); accountTtl = 730 }
                                    catch { self.error = error.localizedDescription }
                                }
                            }
                        }
                    }
                }
            }
            Section {
                Toggle("Back up new photos automatically", isOn: $autoBackup)
                Toggle("Show Lelvo in the menu bar", isOn: $showMenuBarExtra)
            } header: { Text("Backup") } footer: {
                Text(autoBackup ? "While Lelvo is open (even with its window closed), new photos are backed up every hour."
                                : "Nothing uploads on its own: use Back Up Now, or Back Up on the photos you choose.")
            }
            Section {
                Button("Sign Out and Reset This Mac…", role: .destructive) { confirmReset = true }
            } footer: {
                Text("Signs this Mac out of Telegram and removes Lelvo's local data. Your Telegram library isn't touched.")
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
        }
        .formStyle(.grouped)
        .task {
            accountName = await env.td.displayName() ?? (env.td.isReady ? "—" : "Not connected")
            libraryName = await env.library.title()
            accountTtl = await env.td.accountTtlDays()
        }
        .alert("Sign out of Lelvo?", isPresented: $confirmReset) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) {
                app.reset()
                // Settings is its own window: close it and show the welcome screen in the main window.
                dismiss()
                openWindow(id: MacNavigation.mainWindowId)
            }
        } message: {
            Text("This Mac is signed out of Telegram and Lelvo's local data is removed. Your backup in Telegram isn't touched; sign in again to get it back.")
        }
    }
}

// MARK: - Menu bar

struct MenuBarIcon: View {
    @EnvironmentObject private var activity: BackupActivity

    var body: some View {
        Image(systemName: activity.isRunning ? "arrow.triangle.2.circlepath.icloud" : "photo.on.rectangle.angled")
    }
}

/// The menu bar panel: backup status at a glance, with Back Up Now / Pause and a way back to the window.
struct MenuBarStatusView: View {
    @EnvironmentObject private var activity: BackupActivity
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var navigation: MacNavigation
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Prefs.Key.backupPaused) private var paused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: activity.isRunning ? "icloud.and.arrow.up.fill" : "checkmark.icloud.fill")
                    .font(.title2)
                    .foregroundStyle(activity.isRunning ? Color.accentColor : .green)
                    .symbolEffect(.pulse, isActive: activity.isRunning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(activity.isRunning ? "Backing up" : (paused ? "Backup paused" : "Lelvo"))
                        .font(.headline)
                    Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if activity.isRunning && activity.total > 0 {
                ProgressView(value: Double(activity.done), total: Double(max(activity.total, 1)))
                ForEach(activity.lanes.sorted(by: { $0.key < $1.key }), id: \.key) { _, lane in
                    HStack {
                        Text(lane.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if lane.total > 0 {
                            Text("\(Int(Double(lane.sent) / Double(max(lane.total, 1)) * 100))%").monospacedDigit()
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                if app.onboardingComplete {
                    if activity.isRunning {
                        Button("Pause") { AppEnvironment.shared.engine.pause() }
                    } else {
                        Button("Back Up Now") { ContinuedBackup.start(everything: true) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                Spacer()
                Button("Open Lelvo") {
                    openWindow(id: MacNavigation.mainWindowId)
                    NSApp.activate()
                }
            }
            HStack {
                SettingsLink { Text("Settings…") }.buttonStyle(.link)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.link)
            }
            .font(.caption)
        }
        .padding(16)
        .frame(width: 300)
    }

    private var statusText: String {
        if activity.isRunning {
            if let notice = activity.notice { return notice }
            return activity.total > 0 ? "\(activity.done) of \(activity.total) done · \(activity.remaining) left" : "Preparing…"
        }
        if let summary = activity.lastSummary { return summary.text }
        if let last = UserDefaults.standard.object(forKey: Prefs.Key.lastBackupAt) as? Date { return "Last upload \(Format.relative(last))" }
        return "Your photos, in your own Telegram."
    }
}
