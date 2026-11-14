#if DEBUG
import LelvoCore
import SwiftUI

/// Debug only: triggers background work by hand and lists the last runs, so what happened overnight can be checked.
struct BackgroundLabView: View {
    @State private var records = Prefs.runRecords
    @State private var busy = false
    @State private var showNudge = false
    @State private var showSetupEnd = false

    var body: some View {
        List {
            Section {
                Button("Run background refresh now") {
                    busy = true
                    Task {
                        await BackgroundTasks.refreshWork(deadline: Date().addingTimeInterval(22), isCancelled: { false })
                        records = Prefs.runRecords
                        busy = false
                    }
                }
                .disabled(busy)
                Button("Run overnight backup now") {
                    busy = true
                    Task {
                        await BackgroundTasks.processingWork(isCancelled: { false })
                        records = Prefs.runRecords
                        busy = false
                    }
                }
                .disabled(busy)
                Button("Pretend the automation ran") {
                    busy = true
                    Task {
                        _ = try? await BackUpNewPhotosIntent().perform()
                        records = Prefs.runRecords
                        busy = false
                    }
                }
                .disabled(busy)
            } footer: { Text("Runs the Back Up New Photos action, like the Camera automation does.") }

            Section {
                Button("Show the automatic backup sheet") { showNudge = true }
                Button("Show the last setup screen") { showSetupEnd = true }
                Button("Ask about automatic backup again") {
                    Prefs.defaults.removeObject(forKey: Prefs.Key.autoBackupNudges)
                    Prefs.defaults.removeObject(forKey: Prefs.Key.autoBackupNudgedAt)
                }
            } header: { Text("Screens") } footer: {
                Text("The sheet normally shows after a backup you started finishes, while automatic backup is off. The setup screen saves its switch when you tap Start using Lelvo.")
            }

            Section("Last runs") {
                if records.isEmpty { Text("No runs yet").foregroundStyle(.secondary) }
                ForEach(Array(records.suffix(20).reversed().enumerated()), id: \.offset) { _, r in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(r.source.rawValue): uploaded \(r.uploaded), \(r.remaining) waiting")
                        Text("\(r.startedAt.formatted(date: .abbreviated, time: .standard)), \(Int(r.seconds)) s")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Background lab")
        .sheet(isPresented: $showNudge) { AutoBackupNudgeSheet(backedUp: 1_284) }
        .fullScreenCover(isPresented: $showSetupEnd) {
            // A returning library skips the first-photo upload and goes straight to the switch.
            FirstBackupView(restored: 1_284) { showSetupEnd = false }
                .background(Color.black.ignoresSafeArea())
                .preferredColorScheme(.dark)
        }
        .onAppear { records = Prefs.runRecords }
    }
}
#endif
