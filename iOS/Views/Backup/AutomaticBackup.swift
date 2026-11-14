import LelvoCore
import SwiftUI
import UIKit
import UserNotifications

/// Whether the Camera automation is set up and still running, worked out from the recorded runs.
@MainActor
final class AutomationStatus: ObservableObject {
    @Published var health: AutomationHealth = .notSetUp

    func refresh() {
        Task.detached(priority: .utility) {
            let newest = PhotoLibraryService.hasAccess ? AppEnvironment.shared.photos.newestAssetDate() : nil
            let h = BackgroundRuns.automationHealth(Prefs.runRecords, newestPhotoDate: newest, now: Date())
            await MainActor.run { self.health = h }
        }
    }
}

// MARK: - Settings row

/// "Faster backup" under the automatic backup switch.
struct FasterBackupRow: View {
    @StateObject private var status = AutomationStatus()

    var body: some View {
        NavigationLink { AutomaticBackupExplainerView() } label: {
            HStack {
                Text("Faster backup")
                Spacer()
                switch status.health {
                case .notSetUp:
                    Text("Set up").foregroundStyle(.secondary)
                case .working:
                    status("Working", "checkmark.circle.fill", .green)
                case .seemsOff:
                    status("Seems off", "exclamationmark.triangle.fill", .orange)
                }
            }
        }
        // A Label in the row moved the separator under its text instead of under "Faster backup".
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .task { status.refresh() }
    }

    private func status(_ text: String, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(text)
        }
        .foregroundStyle(color)
    }
}

// MARK: - Screen D: how it works

struct AutomaticBackupExplainerView: View {
    @StateObject private var status = AutomationStatus()
    @State private var showSetup = false

    var body: some View {
        List {
            if case .seemsOff = status.health {
                Section {
                    Label("Your automation hasn't run for a while. It may have been turned off.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Fix") { showSetup = true }.fontWeight(.semibold)
                }
            }
            Section("What Lelvo does on its own") {
                row("iphone", "When you open Lelvo", "New photos start backing up at once and keep going after you leave.")
                row("moon.zzz", "Overnight", "Everything still waiting is backed up while your iPhone rests, videos included.")
                row("clock.arrow.circlepath", "Now and then", "iPhone gives Lelvo short moments in the background. New photos go up then.")
            }
            Section("Why it works this way") {
                Text("Lelvo encrypts every photo on this iPhone before it leaves, so only your devices can open it. There is no Lelvo server: photos go straight to your Telegram library.")
                Text("A few seconds after you leave an app, iPhone pauses it, and Lelvo's connection to Telegram closes with it. An upload can't carry on by itself.")
                Text("iPhone has its own way to upload photos in the background, but it sends each photo as it is, unencrypted, to the app maker's server. Lelvo would have to give up encryption and run a server to use it, so it doesn't.")
                Text("Instead Lelvo uses every moment iPhone gives it: when you open it, short moments in the background, and overnight. Photos that wait stay safe on your iPhone and go up at the next one.")
            }
            Section("The Camera automation") {
                Text("The Shortcuts app can wake Lelvo for about 25 seconds each time you close Camera, so the photos you just took go up within a minute. Videos wait for the next time you open Lelvo, or overnight.")
            }
            Section {
                Button { showSetup = true } label: {
                    HStack {
                        Text("Back up new photos within a minute")
                        Spacer()
                        if case .working = status.health {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                }
                .foregroundStyle(.primary)
            } header: { Text("Faster backup (optional)") } footer: {
                Text("About one minute, once. You can remove it any time in the Shortcuts app.")
            }
        }
        .navigationTitle("Automatic backup on iPhone")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showSetup) { AutomationSetupView(finish: { showSetup = false }) }
        .task { status.refresh() }
    }

    private func row(_ symbol: String, _ title: String, _ text: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(Color.accentColor)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Screen E: guided setup

struct AutomationSetupView: View {
    let finish: () -> Void
    @State private var step = 0
    @State private var showCheck = false

    private struct Step { let symbol: String; let text: String }
    // Pictures of the real Shortcuts screens replace the symbols once they're recorded.
    private let steps = [
        Step(symbol: "square.grid.2x2", text: "Open the **Shortcuts** app and tap **Automation** at the bottom."),
        Step(symbol: "plus.circle", text: "Tap **+** (or **New Automation**)."),
        Step(symbol: "app", text: "Scroll down and tap **App**."),
        Step(symbol: "camera", text: "Tap **Choose**, pick **Camera**, then tap **Done**."),
        Step(symbol: "xmark.app", text: "Untick **Is Opened**, tick **Is Closed**."),
        Step(symbol: "bolt", text: "Choose **Run Immediately**, and turn off **Notify When Run**. Tap **Next**."),
        Step(symbol: "icloud.and.arrow.up", text: "Search for **Lelvo**, tap **Back Up New Photos**, then tap **Done**.")
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $step) {
                ForEach(steps.indices, id: \.self) { i in
                    ScrollView {
                        VStack(spacing: 24) {
                            Image(systemName: steps[i].symbol)
                                .font(.system(size: 72, weight: .regular))
                                .foregroundStyle(Color.accentColor)
                                .frame(maxWidth: .infinity, minHeight: 180)
                                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                                .accessibilityHidden(true)
                            Text("Step \(i + 1) of \(steps.count)").font(.footnote).foregroundStyle(.secondary)
                            Text(LocalizedStringKey(steps[i].text))
                                .font(.title3).multilineTextAlignment(.center)
                            if i == steps.count - 1 {
                                Text("If you have Camera in another automation already, add Back Up New Photos to it instead.")
                                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            }
                        }
                        .padding(24)
                    }
                    .tag(i)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Step \(i + 1) of \(steps.count). \(steps[i].text.replacingOccurrences(of: "**", with: ""))")
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            VStack(spacing: 10) {
                Button {
                    UIApplication.shared.open(URL(string: "shortcuts://")!)
                } label: { Label("Open Shortcuts", systemImage: "arrow.up.forward.app").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                HStack {
                    Button("Back") { withAnimation { step -= 1 } }
                        .buttonStyle(.bordered).disabled(step == 0)
                    Spacer()
                    if step < steps.count - 1 {
                        Button("Next") { withAnimation { step += 1 } }.buttonStyle(.borderedProminent)
                    } else {
                        Button("I've set it up") { showCheck = true }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Back up within a minute")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showCheck) {
            AutomationCheckView(showSteps: { showCheck = false }, finish: finish)
        }
    }
}

// MARK: - Screen F: take a photo to check

struct AutomationCheckView: View {
    let showSteps: () -> Void
    let finish: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var opened = Date()
    @State private var works = false
    @State private var gaveUp = false
    @State private var notifying = Prefs.defaults.bool(forKey: Prefs.Key.notifyBackups)

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            if works {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(.green)
                Text("It works. New photos now back up within about a minute.")
                    .font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                if !notifying {
                    Button("Tell me when backups finish") {
                        Task { notifying = await BackupNotifications.enable() }
                    }
                    .buttonStyle(.bordered)
                }
                Button("Done", action: finish).buttonStyle(.borderedProminent)
            } else if gaveUp {
                Image(systemName: "questionmark.circle").font(.system(size: 56)).foregroundStyle(.secondary)
                Text("Nothing yet. Check that the automation says **Is Closed** and **Run Immediately**.")
                    .multilineTextAlignment(.center)
                Button("Show the steps again", action: showSteps).buttonStyle(.borderedProminent)
            } else {
                ProgressView().controlSize(.large)
                Text("Take a photo with Camera, close Camera, then come back here.")
                    .font(.title3).multilineTextAlignment(.center)
                Text("Waiting for the automation…").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(24)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Check it works")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(works)
        .task { await wait() }
        .onChange(of: scenePhase) { _, p in if p == .active { check() } }
        .animation(.default, value: works)
    }

    private func check() {
        guard !works else { return }
        if Prefs.runRecords.contains(where: { $0.source == .shortcut && $0.startedAt >= opened }) {
            works = true
            Haptics.success()
        }
    }

    /// Looks every 2 s for three minutes.
    private func wait() async {
        opened = Date()
        for _ in 0..<90 {
            check()
            if works { return }
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return }
        }
        gaveUp = true
    }
}

// MARK: - Card C: the offer on the Backup tab

/// The guide opens through `showGuide`: a navigation destination can't live inside the List this card sits in.
struct AutomationOfferCard: View {
    let firstFullBackupDone: Bool
    @Binding var showGuide: Bool
    @StateObject private var status = AutomationStatus()
    @AppStorage(Prefs.Key.autoBackup) private var autoBackup = false
    @AppStorage(Prefs.Key.automationOfferSnoozedUntil) private var snoozedUntil: Double = 0
    @AppStorage(Prefs.Key.automationOfferDismissals) private var dismissals = 0

    private var visible: Bool {
        BackgroundRuns.shouldOfferAutomation(
            autoBackup: autoBackup, firstFullBackupDone: firstFullBackupDone, health: status.health,
            snoozedUntil: snoozedUntil > 0 ? Date(timeIntervalSince1970: snoozedUntil) : nil,
            dismissals: dismissals, now: Date())
    }

    var body: some View {
        Group {
            if visible {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Back up new photos within a minute", systemImage: "bolt.fill").font(.headline)
                        Text("Set up a Camera automation once. It takes about a minute.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        HStack {
                            Button("Show me how") { showGuide = true }.buttonStyle(.borderedProminent)
                            Spacer()
                            Button("Not now") {
                                dismissals += 1
                                snoozedUntil = Date().addingTimeInterval(21 * 86_400).timeIntervalSince1970
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .task { status.refresh() }
    }
}
