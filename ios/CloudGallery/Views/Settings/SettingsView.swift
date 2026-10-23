import SwiftUI
import UniformTypeIdentifiers
import CloudGalleryCore

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @AppStorage(Prefs.Key.wifiOnly) private var wifiOnly = true
    @AppStorage(Prefs.Key.backupVideos) private var backupVideos = true
    @AppStorage(Prefs.Key.includeScreenshots) private var includeScreenshots = true
    @AppStorage(Prefs.Key.encryptionEnabled) private var encryption = false
    @AppStorage(Prefs.Key.cacheCapMB) private var cacheCapMB = 500
    @AppStorage(Prefs.Key.allowFreeUpSpace) private var allowFreeUpSpace = false
    @AppStorage(Prefs.Key.botUsername) private var botUsername = ""
    @AppStorage(Prefs.Key.chatTitle) private var chatTitle = ""

    @State private var connection: String?
    @State private var testing = false
    @State private var cacheSizes: (Int64, Int64) = (0, 0)
    @State private var exportURL: URL?
    @State private var showImporter = false
    @State private var restorePassphrase = ""
    @State private var askRestorePassphrase = false
    @State private var pendingImport: URL?
    @State private var alert: GalleryAlert?
    @State private var busy = false
    @State private var confirmReset = false
    @State private var confirmEncryption = false

    private var env: AppEnvironment { AppEnvironment.shared }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Bot", value: botUsername.isEmpty ? "—" : botUsername)
                    LabeledContent("Backup chat", value: chatTitle.isEmpty ? "—" : chatTitle)
                    Button { Task { await testConnection() } } label: {
                        HStack { Text("Test connection"); Spacer(); if testing { ProgressView() } }
                    }
                    if let connection { Text(connection).font(.footnote).foregroundStyle(.secondary) }
                }

                Section {
                    Toggle("Wi-Fi only", isOn: $wifiOnly)
                    Toggle("Back up videos", isOn: $backupVideos)
                    Toggle("Include screenshots", isOn: $includeScreenshots)
                    NavigationLink("Albums") { AlbumPickerView() }
                } header: { Text("Backup") } footer: {
                    Text("With Wi-Fi only on, uploads pause on cellular and resume automatically on Wi-Fi.")
                }

                Section {
                    Toggle("End-to-end encryption", isOn: Binding(get: { encryption }, set: { new in
                        if new { confirmEncryption = true } else { encryption = false }
                    }))
                } header: { Text("Privacy") } footer: {
                    Text("When on, new uploads are encrypted on this iPhone (AES-GCM) before they leave it, so Telegram can't see them. Encrypted files can only be viewed in CloudGallery, not in Telegram. Existing uploads are not changed.")
                }

                Section {
                    Picker("Viewing cache limit", selection: $cacheCapMB) {
                        ForEach([100, 250, 500, 1000, 2000, 5000], id: \.self) { mb in
                            Text(mb >= 1000 ? "\(mb / 1000) GB" : "\(mb) MB").tag(mb)
                        }
                    }
                    LabeledContent("Thumbnails", value: Format.bytes(cacheSizes.0))
                    LabeledContent("Viewed originals", value: Format.bytes(cacheSizes.1))
                    Button("Clear cache", role: .destructive) {
                        env.media.clearCaches()
                        refreshCache()
                        Haptics.success()
                    }
                } header: { Text("Storage") } footer: {
                    Text("Cloud photos you open are kept in a temporary cache; the oldest are removed when it reaches the limit, and iOS can clear it when space is low.")
                }

                Section {
                    Toggle("Allow freeing up space", isOn: $allowFreeUpSpace)
                    if allowFreeUpSpace {
                        Button("Open Free Up Space") { app.openFreeUpSpace() }
                    }
                } footer: {
                    Text("Off by default. When on, you can delete photos from this iPhone that are verified to be in your Telegram backup.")
                }

                Section {
                    Button("Re-upload index now") { run("Index uploaded") { try await env.indexSync.upload() } }
                    Button("Restore from cloud") {
                        run("Restore finished") {
                            guard let pass = env.passphrase else { throw IndexSyncError.notConfigured }
                            let count = try await env.indexSync.restore(passphrase: pass)
                            alert = GalleryAlert(title: "Restored", message: "\(count) items restored from the pinned index.")
                        }
                    }
                    Button("Export encrypted index to Files") {
                        run(nil) { exportURL = try await env.indexSync.exportSealed() }
                    }
                    Button("Restore from exported file") { showImporter = true }
                } header: { Text("Cloud index") } footer: {
                    Text("The index is encrypted with your passphrase and pinned in your chat. A forgotten passphrase can't be recovered.")
                }

                Section("Help") {
                    NavigationLink { AutomationGuideView() } label: { Label("Shortcuts automations", systemImage: "bolt.badge.clock") }
                    NavigationLink { LogsView() } label: { Label("Logs", systemImage: "doc.text.magnifyingglass") }
                    NavigationLink { AboutView() } label: { Label("About & licenses", systemImage: "info.circle") }
                }

                Section {
                    Button("Disconnect and reset app", role: .destructive) { confirmReset = true }
                } footer: {
                    Text("Removes the token, passphrase and local database from this iPhone. Your Telegram channel is not touched.")
                }
            }
            .navigationTitle("Settings")
            .disabled(busy)
            .overlay { if busy { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .onAppear(perform: refreshCache)
            .onChange(of: cacheCapMB) { _, _ in
                env.originalsCache.setCapacity(Prefs.cacheCapBytes)
                refreshCache()
            }
            .sheet(item: Binding(get: { exportURL.map { ShareItems(urls: [$0]) } }, set: { if $0 == nil { exportURL = nil } })) {
                ActivityView(items: $0.urls)
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data]) { result in
                if case .success(let url) = result {
                    pendingImport = url
                    askRestorePassphrase = true
                }
            }
            .alert("Passphrase for this file", isPresented: $askRestorePassphrase) {
                SecureField("Passphrase", text: $restorePassphrase)
                Button("Restore") { importFile() }
                Button("Cancel", role: .cancel) { restorePassphrase = "" }
            }
            .alert("Turn on end-to-end encryption?", isPresented: $confirmEncryption) {
                Button("Turn on") { encryption = true }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("New uploads will only be viewable in CloudGallery. In Telegram they appear as unreadable .cge files. You need your passphrase to restore them on a new phone.")
            }
            .confirmationDialog("Reset CloudGallery on this iPhone?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset", role: .destructive) { app.reset() }
            }
            .alert(item: $alert) { a in Alert(title: Text(a.title), message: Text(a.message)) }
        }
    }

    private func refreshCache() {
        let s = env.media.cacheSizes
        cacheSizes = (s.thumbnails, s.originals)
    }

    private func run(_ success: String?, _ work: @escaping () async throws -> Void) {
        busy = true
        Task {
            do {
                try await work()
                if let success, alert == nil { alert = GalleryAlert(title: success, message: "") }
                Haptics.success()
            } catch {
                alert = GalleryAlert(title: "Something went wrong", message: error.localizedDescription)
                Haptics.error()
            }
            busy = false
        }
    }

    private func importFile() {
        guard let url = pendingImport else { return }
        let pass = restorePassphrase
        restorePassphrase = ""
        run(nil) {
            let count = try await env.indexSync.restore(fromFile: url, passphrase: pass)
            alert = GalleryAlert(title: "Restored", message: "\(count) items restored from the file.")
        }
    }

    private func testConnection() async {
        guard let client = env.client(), let chatId = env.chatId else { connection = "Not configured."; return }
        testing = true
        defer { testing = false }
        do {
            let r = try await client.checkPermissions(chatId: chatId)
            connection = r.isSufficient ? "Connected. The bot has every permission it needs." : "Missing rights: \(r.missing.joined(separator: ", "))."
        } catch {
            connection = error.localizedDescription
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
                Link("AKS-Labs/CloudGallery", destination: URL(string: "https://github.com/AKS-Labs/CloudGallery")!)
            }
            Section("License") {
                Text("GNU General Public License v3.0. You can redistribute and modify this app under the terms of the GPL-3.0.")
                Link("Read the license", destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!)
            }
        }
        .navigationTitle("About")
    }
}
