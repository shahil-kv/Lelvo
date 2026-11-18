#if DEBUG
import SwiftUI
import LelvoCore

/// Debug only: load a large synthetic library to measure grid scroll without a real 40k Photos library.
struct ScrollLibraryLabView: View {
    @State private var busy = false
    @State private var confirmCount: Int?
    @State private var message: String?

    var body: some View {
        List {
            Section {
                Button("Load 10,000 scroll library") { confirmCount = 10_000 }
                    .disabled(busy || !DemoMode.isActive)
                Button("Load 40,000 scroll library") { confirmCount = 40_000 }
                    .disabled(busy || !DemoMode.isActive)
            } footer: {
                Text("Only works in the App Review demo library: it wipes the local index, including changes waiting to be sent to Telegram, so it never runs on a real library. Sign out of the demo to leave it.")
            }
            if let message {
                Section { Text(message).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Scroll library")
        .confirmationDialog(
            "Replace the local index with \(confirmCount?.formatted() ?? "") fake items?",
            isPresented: Binding(get: { confirmCount != nil }, set: { if !$0 { confirmCount = nil } }),
            titleVisibility: .visible
        ) {
            if let n = confirmCount {
                Button("Load \(n.formatted()) items", role: .destructive) { load(n) }
            }
            Button("Cancel", role: .cancel) { confirmCount = nil }
        } message: {
            Text("The demo library is replaced with fake items.")
        }
    }

    private func load(_ count: Int) {
        confirmCount = nil
        busy = true
        message = nil
        Task {
            let n = await Task.detached(priority: .userInitiated) {
                ScrollLibrarySeed.load(count: count)
            }.value
            NotificationCenter.default.post(name: LibraryStore.didChange, object: nil)
            message = "Loaded \(n.formatted()) items. Open Photos and scroll."
            busy = false
        }
    }
}
#endif
