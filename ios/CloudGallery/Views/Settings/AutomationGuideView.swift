import SwiftUI

/// Walks through creating personal automations in the Shortcuts app.
struct AutomationGuideView: View {
    var body: some View {
        List {
            Section {
                Text("Shortcuts can start a backup automatically, without opening CloudGallery. Uploads then continue in the background.")
                Button {
                    UIApplication.shared.open(URL(string: "shortcuts://")!)
                } label: { Label("Open Shortcuts", systemImage: "square.2.layers.3d") }
            }

            Section("Automation 1: When charger is connected") {
                step(1, "Open **Shortcuts** → **Automation** tab → **+** (New Automation).")
                step(2, "Choose **Charger** → **Is Connected**.")
                step(3, "Select **Run Immediately** (and turn off **Notify When Run** if you like).")
                step(4, "Tap **Next**, search for **CloudGallery** and pick **Back Up New Photos**.")
                step(5, "Tap **Done**. Each time you plug in, new photos are queued for upload.")
            }

            Section("Automation 2: Daily at 2 AM") {
                step(1, "**Automation** tab → **+** → **Time of Day**.")
                step(2, "Set **2:00 AM**, repeat **Daily**.")
                step(3, "Select **Run Immediately**.")
                step(4, "Add **CloudGallery → Back Up New Photos**, then **Done**.")
                Text("Tip: leave the phone charging on Wi-Fi overnight. iOS also runs CloudGallery's own overnight catch-up task when the phone is charging.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Other actions") {
                Label("**Backup Status** returns counts you can show in a notification.", systemImage: "chart.bar")
                Label("**Free Up Space** opens the app; iOS always asks you to confirm deletions.", systemImage: "internaldrive")
                Label("You can also say “Back up new photos with CloudGallery” to Siri.", systemImage: "mic")
            }

            Section {
                Text("Each run prepares as many items as it can in about 20 seconds; the rest are picked up by the next run, the overnight task, or **Back up now** in the app.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Automations")
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n).").font(.body.monospacedDigit().bold()).foregroundStyle(.tint)
            Text(text)
        }
    }
}
