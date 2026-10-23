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
    @AppStorage(Prefs.Key.autoBackup) private var autoBackup = true

    @State private var accountName = "…"
    @State private var libraryName = LibraryService.titleDefault
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
                    NavigationLink { LibrarySettingsView() } label: {
                        LabeledContent("Library", value: libraryName)
                    }
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
                    Toggle("Back up new photos automatically", isOn: $autoBackup)
                } footer: {
                    Text(autoBackup
                         ? "New photos matching the choices below are backed up on every run. You can also back up any photo with its Back up button."
                         : "Only photos you choose are backed up: tap Back up on a photo, or select several in Photos and tap Back up.")
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
                libraryName = await env.library.title()
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

/// The library channel: rename it, or switch to another library (restores it and re-links this iPhone).
struct LibrarySettingsView: View {
    @State private var name = ""
    @State private var savedName = ""
    @State private var channels: [LibraryService.ChannelChoice] = []
    @State private var loading = false
    @State private var switching: LibraryService.ChannelChoice?
    @State private var passphrase = ""
    @State private var busy: String?
    @State private var alert: GalleryAlert?
    private var env: AppEnvironment { AppEnvironment.shared }

    var body: some View {
        Form {
            Section {
                TextField("Library name", text: $name)
                    .submitLabel(.done)
                    .onSubmit(save)
                if name != savedName && !name.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button("Save name", action: save)
                }
            } header: { Text("Name") } footer: {
                Text("Renames the channel in Telegram. CloudGallery recognises your library by a hidden marker, so the name can be anything.")
            }

            Section {
                LabeledContent("Encryption", value: env.library.isEncrypted ? "End-to-end" : "Standard")
            }

            Section {
                if loading { HStack { ProgressView(); Text("Looking for libraries…").foregroundStyle(.secondary) } }
                ForEach(channels.filter { $0.isLibrary && $0.id != env.library.chatId }) { c in
                    Button { switching = c; passphrase = "" } label: {
                        HStack {
                            Label(c.title, systemImage: c.encrypted ? "lock.shield.fill" : "photo.stack.fill")
                            Spacer()
                            Text(c.encrypted ? "Encrypted" : "Standard").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !loading && !channels.contains(where: { $0.isLibrary && $0.id != env.library.chatId }) {
                    Text("No other libraries in this Telegram account.").foregroundStyle(.secondary)
                }
            } header: { Text("Switch library") } footer: {
                Text("Switching loads the other library from Telegram and links your photos to it. Nothing is deleted from either library.")
            }
        }
        .navigationTitle("Library")
        .disabled(busy != nil)
        .overlay {
            if let busy {
                ProgressView(busy).padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .task { await load() }
        .alert(item: $alert) { a in Alert(title: Text(a.title), message: Text(a.message)) }
        .sheet(item: $switching) { c in
            NavigationStack {
                Form {
                    Section {
                        Text("Switch to “\(c.title)”? The backup restarts against that library.")
                        if c.encrypted {
                            SecureField("Passphrase", text: $passphrase).textContentType(.password)
                        }
                    }
                }
                .navigationTitle("Switch library")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { switching = nil } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Switch") { switchTo(c) }.disabled(c.encrypted && passphrase.isEmpty)
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    private func load() async {
        loading = true
        savedName = await env.library.title()
        if name.isEmpty { name = savedName }
        channels = (try? await env.library.candidateChannels()) ?? []
        loading = false
    }

    private func save() {
        let new = name
        Task {
            busy = "Renaming…"
            defer { busy = nil }
            do {
                try await env.library.rename(new)
                savedName = new
                Haptics.success()
            } catch { alert = GalleryAlert(title: "Couldn't rename", message: error.localizedDescription) }
        }
    }

    private func switchTo(_ c: LibraryService.ChannelChoice) {
        let pass = c.encrypted ? passphrase : nil
        switching = nil
        Task {
            busy = "Switching to \(c.title)…"
            defer { busy = nil }
            do {
                try await env.switchLibrary(to: c.id, passphrase: pass)
                Haptics.success()
                ContinuedBackup.start()
                await load()
                alert = GalleryAlert(title: "Switched", message: "Now using “\(c.title)”.")
            } catch {
                Haptics.error()
                alert = GalleryAlert(title: "Couldn't switch", message: error.localizedDescription)
            }
        }
    }
}
