import SwiftUI
import MemvoCore

/// Which kinds of memories to make, like Google Photos' Memory types. All on by default.
struct MemoriesSettingsView: View {
    @AppStorage("memories.onThisDay") private var onThisDay = true
    @AppStorage("memories.recent") private var recent = true
    @AppStorage("memories.trips") private var trips = true
    @AppStorage("memories.themes") private var themes = true

    static let didChange = Notification.Name("Memvo.memoriesSettingsChanged")

    /// The kinds turned on.
    static var enabled: Set<Memories.KindFilter> {
        Set(Memories.KindFilter.allCases.filter { UserDefaults.standard.object(forKey: "memories.\($0.rawValue)") as? Bool ?? true })
    }

    var body: some View {
        Form {
            Section {
                Toggle("Years ago on this day", isOn: $onThisDay)
                Toggle("Recent highlights", isOn: $recent)
                Toggle("Trips", isOn: $trips)
                Toggle("Themes: pets, beaches, food and more", isOn: $themes)
            } footer: {
                Text("Memories are made on this \(Device.name) from your photos' dates, places and what's in them. Nothing is sent anywhere.")
            }
        }
        .platformGroupedForm()
        .navigationTitle("Memories")
        .onChange(of: [onThisDay, recent, trips, themes]) { _, _ in NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }
}
