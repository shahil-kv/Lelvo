import SwiftUI
import LelvoCore

/// Which kinds of memories to make, like Google Photos' Memory types. On This Day / recent / trips stay free;
/// theme stories (pets, beaches…) are Lelvo Pro (#16E).
struct MemoriesSettingsView: View {
    @ObservedObject private var pro = ProStore.shared
    @AppStorage("memories.onThisDay") private var onThisDay = true
    @AppStorage("memories.recent") private var recent = true
    @AppStorage("memories.trips") private var trips = true
    @AppStorage("memories.themes") private var themes = true
    @State private var showProPaywall = false

    static let didChange = Notification.Name("Lelvo.memoriesSettingsChanged")

    /// The kinds whose toggles are on (does not apply the Pro gate — callers do).
    static var enabled: Set<Memories.KindFilter> {
        Set(Memories.KindFilter.allCases.filter {
            UserDefaults.standard.object(forKey: "memories.\($0.rawValue)") as? Bool ?? true
        })
    }

    var body: some View {
        Form {
            Section {
                Toggle("Years ago on this day", isOn: $onThisDay)
                Toggle("Recent highlights", isOn: $recent)
                Toggle("Trips", isOn: $trips)
                if pro.isPro {
                    Toggle("Themes: pets, beaches, food and more", isOn: $themes)
                } else {
                    Button { showProPaywall = true } label: {
                        HStack {
                            Text("Themes: pets, beaches, food and more")
                            Spacer()
                            ProBadge()
                        }
                    }
                }
            } footer: {
                Text(pro.isPro
                     ? "Memories are made on this \(Device.name) from your photos' dates, places and what's in them. Nothing is sent anywhere."
                     : "On this day, recent highlights and trips stay free. Theme stories need Lelvo Pro.")
            }
        }
        .platformGroupedForm()
        .navigationTitle("Memories")
        .onChange(of: [onThisDay, recent, trips, themes]) { _, _ in NotificationCenter.default.post(name: Self.didChange, object: nil) }
        .onChange(of: pro.isPro) { _, _ in NotificationCenter.default.post(name: Self.didChange, object: nil) }
        .sheet(isPresented: $showProPaywall) { ProPaywallView() }
    }
}
