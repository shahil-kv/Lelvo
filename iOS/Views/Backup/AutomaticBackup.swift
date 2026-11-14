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

// MARK: - Backup options row

/// "Back up within a minute" at the top of Backup options, with whether the Camera automation works.
struct MinuteBackupRow: View {
    @StateObject private var status = AutomationStatus()

    var body: some View {
        NavigationLink { AutomaticBackupExplainerView() } label: {
            HStack {
                Label("Back up within a minute", systemImage: "bolt.fill")
                Spacer()
                switch status.health {
                case .notSetUp:
                    Text("Set up").foregroundStyle(.secondary)
                case .working:
                    state("Working", "checkmark.circle.fill", .green)
                case .seemsOff:
                    state("Seems off", "exclamationmark.triangle.fill", .orange)
                }
            }
        }
        .task { status.refresh() }
    }

    private func state(_ text: String, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(text)
        }
        .foregroundStyle(color)
    }
}

// MARK: - Screen D: automatic backup

struct AutomaticBackupExplainerView: View {
    @StateObject private var status = AutomationStatus()
    @State private var showSetup = false

    private var working: Bool { if case .working = status.health { return true } else { return false } }

    var body: some View {
        List {
            Section {
                if working {
                    Label("New photos back up within a minute of closing Camera.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .padding(.vertical, 4)
                } else {
                    BackupTimingComparison()
                }
            }
            if case .seemsOff = status.health {
                Section {
                    Label("Your Camera automation hasn't run for a while. It may have been turned off.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Fix") { showSetup = true }.fontWeight(.semibold)
                }
            }
            Section("Lelvo backs up") {
                row("iphone", "When you open Lelvo", "Starts at once and keeps going after you leave")
                row("clock", "Now and then", "In short moments iPhone gives Lelvo")
                row("moon.zzz", "Overnight", "Everything left, videos too")
            }
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Back up within a minute", systemImage: "bolt.fill").font(.headline)
                    Text("Add a Camera automation once. Every time you close Camera, the photos you took go up. Videos wait for the moments above.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button { showSetup = true } label: {
                        Text(working ? "Show the steps again" : "Set up, about 1 minute").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .padding(.top, 4)
                }
                .padding(.vertical, 6)
            } footer: {
                Text("You can remove it any time in the Shortcuts app.")
            }
            Section {
                DisclosureGroup("Why does iPhone need this?") {
                    Text("Your photos are encrypted on this iPhone and go straight to your Telegram library. There is no Lelvo server. iPhone pauses apps soon after you leave them, which closes the connection to Telegram, so Lelvo backs up at the moments above instead.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Automatic backup")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showSetup) { AutomationSetupView(finish: { showSetup = false }) }
        .task { status.refresh() }
    }

    private func row(_ symbol: String, _ title: String, _ text: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(text).font(.footnote).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(Color.accentColor)
        }
        .accessibilityElement(children: .combine)
    }
}

/// "You take a photo at 10:02": today it waits until Lelvo is opened; with the automation it's safe a minute later.
/// Two clocks roll forward so the difference is felt, not read. Plays on appear; a tap plays it again.
struct BackupTimingComparison: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var todayMinutes = start
    @State private var fastMinutes = start
    @State private var todayFill = 0.0
    @State private var fastFill = 0.0
    @State private var run = 0

    private static let start = 10 * 60 + 2
    private static let opened = 13 * 60 + 40

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("You take a photo at \(Self.clock(Self.start))").font(.headline)
                Text("When is it safe in your Telegram library?").font(.subheadline).foregroundStyle(.secondary)
            }
            lane(title: "Today", minutes: todayMinutes, fill: todayFill, color: .orange,
                 done: todayMinutes == Self.opened, when: "when you open Lelvo")
            lane(title: "With Camera automation", minutes: fastMinutes, fill: fastFill, color: .accentColor,
                 done: fastMinutes == Self.start + 1, when: "right after you close Camera", good: true)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { run += 1 }
        .task(id: run) { await play() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("You take a photo at \(Self.clock(Self.start)). Today it's backed up when you open Lelvo, which can be hours later. With the Camera automation it's backed up right after you close Camera, a minute later.")
    }

    private func lane(title: String, minutes: Int, fill: Double, color: Color, done: Bool, when: String, good: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold)).tracking(0.5)
                .foregroundStyle(good ? Color.accentColor : Color.secondary)
            HStack(spacing: 10) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(.tertiarySystemFill))
                        Capsule().fill(color).frame(width: g.size.width * fill)
                    }
                }
                .frame(height: 4)
                VStack(alignment: .trailing, spacing: 0) {
                    HStack(spacing: 4) {
                        Text(Self.clock(minutes))
                            .contentTransition(.numericText(countsDown: false))
                        if done && good {
                            Image(systemName: "checkmark.circle.fill").transition(.scale.combined(with: .opacity))
                        }
                    }
                    .font(.title3.weight(.bold)).monospacedDigit()
                    .foregroundStyle(done ? (good ? Color.green : Color.orange) : Color.primary)
                    Text(when).font(.caption2).foregroundStyle(.secondary)
                }
                .frame(minWidth: 120, alignment: .trailing)
            }
        }
        .padding(10)
        .background(Color(.tertiarySystemFill).opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func play() async {
        todayMinutes = Self.start; fastMinutes = Self.start; todayFill = 0; fastFill = 0
        if reduceMotion {
            todayMinutes = Self.opened; fastMinutes = Self.start + 1; todayFill = 1; fastFill = 1
            return
        }
        try? await Task.sleep(for: .seconds(0.5))
        withAnimation(.easeInOut(duration: 0.6)) { fastFill = 1 }
        withAnimation(.easeInOut(duration: 3.6)) { todayFill = 1 }
        let steps = 36
        for i in 1...steps {
            try? await Task.sleep(for: .seconds(0.1))
            if Task.isCancelled { return }
            withAnimation(.snappy(duration: 0.2)) {
                if i == 6 { fastMinutes = Self.start + 1 }
                todayMinutes = Self.start + (Self.opened - Self.start) * i / steps
            }
        }
    }

    /// 10:02 shown the way this iPhone shows times (12 or 24 hours).
    private static func clock(_ minutes: Int) -> String {
        let date = Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Screen E: guided setup

struct AutomationSetupView: View {
    let finish: () -> Void
    @State private var step = 0
    @State private var showCheck = false

    private let steps: [String] = [
        "Open **Shortcuts**, tap **Automation**, then **+** (or **New Automation**).",
        "Scroll down and tap **App**.",
        "Choose **Camera**, tick **Is Opened** and **Is Closed**, and choose **Run Immediately**. Tap **Next**.",
        "Search for **Lelvo** and tap **Back Up New Photos**. Turn off **Show When Run**, then tap **Done**."
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $step) {
                ForEach(steps.indices, id: \.self) { i in
                    ScrollView {
                        VStack(spacing: 18) {
                            ShortcutsMock(step: i, active: step == i)
                                .frame(height: 280)
                                .accessibilityHidden(true)
                            Text("Step \(i + 1) of \(steps.count)").font(.footnote).foregroundStyle(.secondary)
                            Text(LocalizedStringKey(steps[i]))
                                .font(.title3).multilineTextAlignment(.center)
                            if i == steps.count - 1 {
                                Text("If Camera is already in another automation, add Back Up New Photos to that one instead.")
                                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            }
                        }
                        .padding(24)
                    }
                    .tag(i)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Step \(i + 1) of \(steps.count). \(steps[i].replacingOccurrences(of: "**", with: ""))")
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            VStack(spacing: 10) {
                Button {
                    UIApplication.shared.open(URL(string: "shortcuts://")!)
                } label: { Label("Open Shortcuts", systemImage: "arrow.up.forward.app").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large)
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
        .navigationTitle("Set up in Shortcuts")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showCheck) {
            AutomationCheckView(showSteps: { showCheck = false }, finish: finish)
        }
    }
}

/// A drawing of the Shortcuts screen for each step, with a ring on what to tap. Drawn rather than screenshots so it
/// follows light and dark mode and Dynamic Type.
private struct ShortcutsMock: View {
    let step: Int
    let active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch step {
            case 0:
                HStack {
                    Text("Automation").font(.title2.bold())
                    Spacer()
                    Image(systemName: "plus").font(.headline).foregroundStyle(Color.accentColor)
                        .frame(width: 32, height: 32).background(Color(.tertiarySystemFill), in: Circle())
                        .overlay { TapRing(active: active, delay: 0.6) }
                }
                row(nil, "No automations yet").opacity(0.5)
                Spacer()
                HStack {
                    Spacer(); Text("Shortcuts"); Spacer()
                    Text("Automation").fontWeight(.bold).foregroundStyle(Color.accentColor); Spacer()
                    Text("Gallery"); Spacer()
                }
                .font(.caption).foregroundStyle(.secondary)
            case 1:
                Text("When").font(.title2.bold())
                row(("clock.fill", .orange), "Time of Day")
                row(("airplane", .indigo), "Airplane Mode")
                row(("square.grid.2x2.fill", .blue), "App", ring: 0.6)
                row(("battery.100", .green), "Battery Level")
            case 2:
                Text("App").font(.title2.bold())
                row(("camera.fill", .gray), "Camera", trailing: "Chosen")
                // Opened as well: photos a missed run left behind (Camera from the lock screen) go up next time.
                row(nil, "Is Opened", check: true, ring: 0.6)
                row(nil, "Is Closed", check: true, ring: 1.2)
                row(nil, "Run Immediately", check: true, ring: 1.8)
            default:
                Text("Do").font(.title2.bold())
                row(("magnifyingglass", .gray), "Lelvo")
                row(("icloud.and.arrow.up.fill", .accentColor), "Back Up New Photos", ring: 0.6)
                // On by default, it shows a box every time Camera closes.
                row(nil, "Show When Run", switchOff: true, ring: 1.6)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color(.separator), lineWidth: 0.5))
    }

    private func row(_ icon: (String, Color)?, _ title: String, trailing: String? = nil, check: Bool? = nil,
                     switchOff: Bool = false, ring: Double? = nil) -> some View {
        HStack(spacing: 10) {
            if let icon {
                Image(systemName: icon.0).font(.caption.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 26, height: 26).background(icon.1, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            Text(title).font(.subheadline)
            Spacer()
            if let trailing { Text(trailing).font(.subheadline).foregroundStyle(Color.accentColor) }
            if let check {
                Image(systemName: check ? "checkmark" : "circle")
                    .foregroundStyle(check ? Color.accentColor : Color(.tertiaryLabel))
                    .fontWeight(.semibold)
            }
            if switchOff {
                Capsule().fill(Color(.systemFill)).frame(width: 40, height: 24)
                    .overlay(alignment: .leading) { Circle().fill(.white).padding(2).shadow(radius: 1) }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(Color(.systemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .trailing) { if let ring { TapRing(active: active, delay: ring).padding(.trailing, 14) } }
    }
}

/// A finger tap: the ring lands, presses in and fades. Plays when its step comes on screen.
private struct TapRing: View {
    let active: Bool
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = 0

    var body: some View {
        Circle()
            .fill(Color.white.opacity(0.45))
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
            .frame(width: 32, height: 32)
            .scaleEffect(phase == 0 ? 1.6 : phase == 2 ? 0.8 : 1)
            .opacity(phase == 1 || phase == 2 ? 1 : 0)
            .allowsHitTesting(false)
            .task(id: active) {
                phase = 0
                guard active, !reduceMotion else { return }
                try? await Task.sleep(for: .seconds(delay))
                withAnimation(.easeOut(duration: 0.25)) { phase = 1 }
                try? await Task.sleep(for: .seconds(0.3))
                withAnimation(.easeOut(duration: 0.15)) { phase = 2 }
                try? await Task.sleep(for: .seconds(0.2))
                withAnimation(.easeOut(duration: 0.4)) { phase = 3 }
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
                Text("Nothing yet. Check that the automation says **Is Opened**, **Is Closed** and **Run Immediately**.")
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
