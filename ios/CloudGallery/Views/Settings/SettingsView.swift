import SwiftUI
import CloudGalleryCore

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @AppStorage(Prefs.Key.wifiOnly) private var wifiOnly = true
    @AppStorage(Prefs.Key.chargingOnly) private var chargingOnly = false
    @AppStorage(Prefs.Key.mediaFilter) private var mediaFilter = Prefs.MediaFilter.all.rawValue
    @AppStorage(Prefs.Key.includeScreenshots) private var includeScreenshots = true
    @AppStorage(Prefs.Key.dateFromEnabled) private var dateFromEnabled = false
    @AppStorage(Prefs.Key.dateFrom) private var dateFrom: Double = Date().addingTimeInterval(-365 * 86400).timeIntervalSince1970
    @AppStorage(Prefs.Key.cacheCapMB) private var cacheCapMB = 1000
    @AppStorage(Prefs.Key.thumbnailCacheMB) private var thumbnailCacheMB = 300
    @AppStorage(Prefs.Key.allowFreeUpSpace) private var allowFreeUpSpace = false

    @State private var accountName = "…"
    @State private var usage: CloudMediaService.CacheUsage?
    @State private var alert: GalleryAlert?
    @State private var busy = false
    @State private var confirmReset = false

    private var env: AppEnvironment { AppEnvironment.shared }

    var body: some View {
        NavigationStack {
            Form {
                Section("Telegram") {
                    LabeledContent("Signed in as", value: accountName)
                    LabeledContent("Library", value: LibraryService.titleDefault)
                    LabeledContent("Encryption", value: env.library.isEncrypted ? "End-to-end (on)" : "Off")
                    Button("Re-scan library from Telegram") {
                        run("Library re-scanned") {
                            let s = try await env.library.scan(full: true)
                            alert = GalleryAlert(title: "Library re-scanned",
                                                 message: "\(s.items) items found\(s.incomplete > 0 ? ", \(s.incomplete) incomplete" : "")\(s.orphans.isEmpty ? "" : ", \(s.orphans.count) duplicate messages").")
                        }
                    }
                }

                Section {
                    Picker("Back up", selection: $mediaFilter) {
                        ForEach(Prefs.MediaFilter.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Toggle("Include screenshots", isOn: $includeScreenshots)
                    NavigationLink("Albums") { AlbumPickerView() }
                    Toggle("Only photos taken after a date", isOn: $dateFromEnabled)
                    if dateFromEnabled {
                        DatePicker("From", selection: Binding(get: { Date(timeIntervalSince1970: dateFrom) },
                                                              set: { dateFrom = $0.timeIntervalSince1970 }),
                                   displayedComponents: .date)
                    }
                    Toggle("Wi-Fi only", isOn: $wifiOnly)
                    Toggle("Only while charging", isOn: $chargingOnly)
                } header: { Text("What to back up") } footer: {
                    Text("Wi-Fi only also pauses on personal hotspots and Low Data Mode.")
                }

                Section {
                    Picker("Viewing cache", selection: $cacheCapMB) {
                        ForEach([250, 500, 1000, 2000, 5000], id: \.self) { mb in Text(mb >= 1000 ? "\(mb / 1000) GB" : "\(mb) MB").tag(mb) }
                    }
                    Picker("Thumbnail cache", selection: $thumbnailCacheMB) {
                        ForEach([100, 300, 600, 1000], id: \.self) { mb in Text(mb >= 1000 ? "1 GB" : "\(mb) MB").tag(mb) }
                    }
                    if let usage {
                        LabeledContent("Thumbnails", value: Format.bytes(usage.thumbnails))
                        LabeledContent("Viewed photos", value: Format.bytes(usage.originals))
                        LabeledContent("Video & Telegram files", value: Format.bytes(usage.telegram))
                    }
                    Button("Clear cache", role: .destructive) {
                        run(nil) {
                            await env.media.clearCaches()
                            refreshUsage()
                            Haptics.success()
                        }
                    }
                } header: { Text("Storage") } footer: {
                    Text("Viewing cloud items only fills these caches; the oldest entries are removed automatically and iOS may clear them when space is low.")
                }

                Section {
                    Toggle("Allow freeing up space", isOn: $allowFreeUpSpace)
                    if allowFreeUpSpace { Button("Open Free Up Space") { app.openFreeUpSpace() } }
                } footer: {
                    Text("Off by default. When on, you can delete photos from this iPhone that are verified to be in your Telegram library.")
                }

                Section("Help") {
                    NavigationLink { AutomationGuideView() } label: { Label("Shortcuts automations", systemImage: "bolt.badge.clock") }
                    NavigationLink { LogsView() } label: { Label("Logs", systemImage: "doc.text.magnifyingglass") }
                    NavigationLink { AboutView() } label: { Label("About & licenses", systemImage: "info.circle") }
                }

                Section {
                    Button("Sign out and reset this iPhone", role: .destructive) { confirmReset = true }
                } footer: {
                    Text("Signs out of Telegram on this iPhone and removes local data. Your Telegram library is not touched; sign in again to restore it.")
                }
            }
            .navigationTitle("Settings")
            .disabled(busy)
            .overlay { if busy { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .task {
                refreshUsage()
                accountName = await env.td.displayName() ?? (env.td.isReady ? "—" : "Not connected")
            }
            .onChange(of: cacheCapMB) { _, _ in Task { await env.enforceCacheLimits(); refreshUsage() } }
            .onChange(of: thumbnailCacheMB) { _, _ in Task { await env.enforceCacheLimits(); refreshUsage() } }
            .confirmationDialog("Sign out and reset CloudGallery on this iPhone?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Sign out and reset", role: .destructive) { run(nil) { await app.reset() } }
            }
            .alert(item: $alert) { a in Alert(title: Text(a.title), message: Text(a.message)) }
        }
    }

    private func refreshUsage() {
        Task.detached { let u = AppEnvironment.shared.media.cacheUsage; await MainActor.run { usage = u } }
    }

    private func run(_ success: String?, _ work: @escaping () async throws -> Void) {
        busy = true
        Task {
            do {
                try await work()
                if let success, alert == nil { alert = GalleryAlert(title: success, message: "") }
            } catch {
                alert = GalleryAlert(title: "Something went wrong", message: error.localizedDescription)
                Haptics.error()
            }
            busy = false
        }
    }
}

struct AlbumPickerView: View {
    @AppStorage(Prefs.Key.albumMode) private var mode = Prefs.AlbumMode.all.rawValue
    @State private var albums: [AlbumInfo] = []
    @State private var selected = Prefs.albumIds

    var body: some View {
        List {
            Picker("Back up", selection: $mode) {
                ForEach(Prefs.AlbumMode.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.inline)
            if mode != Prefs.AlbumMode.all.rawValue {
                Section(mode == Prefs.AlbumMode.include.rawValue ? "Include" : "Exclude") {
                    ForEach(albums) { album in
                        Button {
                            if selected.contains(album.id) { selected.remove(album.id) } else { selected.insert(album.id) }
                            Prefs.albumIds = selected
                        } label: {
                            HStack {
                                Text(album.title).foregroundStyle(.primary)
                                Spacer()
                                Text("\(album.count)").foregroundStyle(.secondary)
                                if selected.contains(album.id) { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                        .accessibilityAddTraits(selected.contains(album.id) ? .isSelected : [])
                    }
                }
            }
        }
        .navigationTitle("Albums")
        .task { albums = AppEnvironment.shared.photos.userAlbums() }
    }
}

struct LogsView: View {
    @State private var text = ""
    @State private var share: ShareItems?

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "No log entries yet." : text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Logs")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { if let url = AppLog.shared.exportFile() { share = ShareItems(urls: [url]) } } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share logs")
                Button(role: .destructive) { AppLog.shared.clear(); text = "" } label: { Image(systemName: "trash") }
                    .accessibilityLabel("Clear logs")
            }
        }
        .safeAreaInset(edge: .top) {
            Text("Bot token, chat ID and passphrase are removed from logs before they are shown or shared.")
                .font(.caption2).foregroundStyle(.secondary).padding(.horizontal).padding(.top, 4)
        }
        .task { text = AppLog.shared.contents() }
        .sheet(item: $share) { ActivityView(items: $0.urls) }
    }
}

struct AboutView: View {
    var body: some View {
        List {
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                Text("CloudGallery for iOS backs up your photos to your own Telegram channel. No analytics, no tracking, no servers.")
            }
            Section("Credits") {
                Text("Based on the ideas of **AKS-Labs/CloudGallery** (Android) and **Whitehole**, the original Telegram photo-backup projects.")
                Link("AKS-Labs/CloudGallery", destination: .literal("https://github.com/AKS-Labs/CloudGallery"))
            }
            Section("License") {
                Text("GNU General Public License v3.0. You can redistribute and modify this app under the terms of the GPL-3.0.")
                Link("Read the license", destination: .literal("https://www.gnu.org/licenses/gpl-3.0.html"))
            }
        }
        .navigationTitle("About")
    }
}
