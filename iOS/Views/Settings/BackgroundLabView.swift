#if DEBUG
import LelvoCore
import SwiftUI

/// Debug only: triggers background work by hand and lists the last runs, so what happened overnight can be checked.
struct BackgroundLabView: View {
    @State private var records = Prefs.runRecords
    @State private var busy = false

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
        .onAppear { records = Prefs.runRecords }
    }
}
#endif
