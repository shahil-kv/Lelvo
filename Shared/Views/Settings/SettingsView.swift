import SwiftUI
import UniformTypeIdentifiers
import LelvoCore

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @AppStorage(Prefs.Key.wifiOnly) private var wifiOnly = true
    @AppStorage(Prefs.Key.chargingOnly) private var chargingOnly = false
    @AppStorage(Prefs.Key.mediaFilter) private var mediaFilter = Prefs.MediaFilter.all.rawValue
    @AppStorage(Prefs.Key.autoBackup) private var autoBackup = false

    @State private var accountName = "…"
    @State private var libraryName = LibraryService.titleDefault
    @State private var accountTtl: Int?
    @State private var usage: CloudMediaService.CacheUsage?
    @State private var alert: GalleryAlert?
    @State private var busy = false
    @State private var confirmReset = false

    private var env: AppEnvironment { AppEnvironment.shared }
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Signed in as", value: accountName)
                    NavigationLink { LibrarySettingsView() } label: {
                        LabeledContent("Library", value: libraryName)
                    }
                    .onAppear { Task { libraryName = await env.library.title() } }
                    LabeledContent("Encryption", value: env.library.isEncrypted ? "End-to-end" : "Standard")
                    if let days = accountTtl, days >= 730 {
                        Label("Account kept for 2 years without use", systemImage: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                            .font(.subheadline)
                    }
                    if let days = accountTtl, days < 730 {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Telegram deletes your account after \(days >= 365 ? "\(days / 365) year" : "\(days / 30) months") of inactivity, and your library with it.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote).foregroundStyle(.orange)
                            Button("Change to 2 years (the maximum)") {
                                run("Set to 2 years") {
                                    try await env.td.setAccountTtl(days: 730)
                                    accountTtl = 730
                                }
                            }
                            .font(.subheadline.weight(.semibold))
                        }
                        .padding(.vertical, 4)
                    }
                } header: { Text("Telegram") }

                Section {
                    Toggle("Back up new photos automatically", isOn: $autoBackup)
                    NavigationLink { BackupOptionsView() } label: {
                        LabeledContent("Backup options", value: backupSummary)
                    }
                } header: { Text("Backup") } footer: {
                    Text(autoBackup
                         ? "New photos are backed up on their own, including overnight while charging."
                         : "Nothing uploads on its own: use Back up now on the Backup tab, or Back up on the photos you choose.")
                }

                Section {
                    NavigationLink("Memories") { MemoriesSettingsView() }
                }

                Section {
                    NavigationLink { StorageSettingsView() } label: {
                        LabeledContent("Storage", value: usage.map { Format.bytes($0.thumbnails + $0.originals + $0.telegram) } ?? "…")
                    }
                } footer: {
                    Text("Space used on this \(Device.name) by cloud previews you've viewed. Your photos aren't affected.")
                }

                Section {
                    NavigationLink { ExportLibraryView() } label: {
                        Label("Download a copy of your library", systemImage: "square.and.arrow.down.on.square")
                    }
                } header: { Text("Your data") } footer: {
                    Text("Everything you've backed up, saved to Files or an external drive. Your library is never locked in.")
                }

                Section("Help") {
                    #if os(iOS)
                    NavigationLink { AutomationGuideView() } label: { Label("Shortcuts automations", systemImage: "bolt.badge.clock") }
                    #endif
                    NavigationLink { FeedbackView(kind: .bug) } label: { Label("Report a problem", systemImage: "ladybug") }
                    NavigationLink { FeedbackView(kind: .idea) } label: { Label("Suggest a feature", systemImage: "lightbulb") }
                    NavigationLink { LogsView() } label: { Label("Logs", systemImage: "doc.text.magnifyingglass") }
                    NavigationLink { AboutView() } label: { Label("About & licenses", systemImage: "info.circle") }
                }

                Section {
                    Button("Sign out and reset this \(Device.name)", role: .destructive) { confirmReset = true }
                } footer: {
                    Text("Signs out of Telegram on this \(Device.name) and removes local data. Your Telegram library is not touched; sign in again to restore it.")
                }
            }
            .navigationTitle("Settings")
            // Opened as a sheet from the gear in Photos.
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .disabled(busy)
            .overlay { if busy { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .task {
                refreshUsage()
                if DemoMode.isActive {
                    accountName = "Demo account"
                    libraryName = "Demo library"
                    return
                }
                accountName = await env.td.displayName() ?? (env.td.isReady ? "—" : "Not connected")
                libraryName = await env.library.title()
                accountTtl = await env.td.accountTtlDays()
            }
            .alert("Sign out of Lelvo?", isPresented: $confirmReset) {
                Button("Cancel", role: .cancel) {}
                Button("Sign Out", role: .destructive) { app.reset() }
            } message: {
                Text("This \(Device.name) is signed out of Telegram and Lelvo's local data is removed. Your backup in Telegram isn't touched; sign in again to get it back.")
            }
            .alert(item: $alert) { a in Alert(title: Text(a.title), message: Text(a.message)) }
        }
    }

    private var backupSummary: String {
        var parts: [String] = [Prefs.MediaFilter(rawValue: mediaFilter)?.title ?? "Photos and videos"]
        if wifiOnly { parts.append("Wi-Fi") }
        if chargingOnly { parts.append("charging") }
        return parts.joined(separator: ", ")
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
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    guard let url = AppLog.shared.exportFile() else { return }
                    #if os(macOS)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    #else
                    share = ShareItems(urls: [url])
                    #endif
                } label: {
                    Image(systemName: Device.name == "Mac" ? "folder" : "square.and.arrow.up")
                }
                .accessibilityLabel(Device.name == "Mac" ? "Show log file in Finder" : "Share logs")
                Button(role: .destructive) { AppLog.shared.clear(); text = "" } label: { Image(systemName: "trash") }
                    .accessibilityLabel("Clear logs")
            }
        }
        .safeAreaInset(edge: .top) {
            Text("Phone numbers, API keys, channel IDs and file IDs are removed from logs before they are shown or shared.")
                .font(.caption2).foregroundStyle(.secondary).padding(.horizontal).padding(.top, 4)
        }
        .task { text = AppLog.shared.contents() }
        #if os(iOS)
        .sheet(item: $share) { ActivityView(items: $0.urls) }
        #endif
    }
}

struct AboutView: View {
    var body: some View {
        List {
            Section {
                LabeledContent("Version", value: Bundle.main.displayVersion)
                Text("Lelvo backs up your photos to a private channel in your own Telegram account. No servers, no analytics, no ads.")
            }
            Section {
                Link(destination: AppLinks.faq) { Label("Questions and answers", systemImage: "questionmark.circle") }
                NavigationLink { FeedbackView(kind: .bug) } label: { Label("Report a problem", systemImage: "ladybug") }
                NavigationLink { FeedbackView(kind: .idea) } label: { Label("Suggest a feature", systemImage: "lightbulb") }
                Link(destination: AppLinks.privacyPolicy) { Label("Privacy policy", systemImage: "hand.raised") }
            } header: { Text("Help") }
            Section {
                Text("Lelvo is free software: you can redistribute it and modify it under the terms of the GNU General Public License, version 3. It comes with no warranty.")
                Link(destination: AppLinks.repository) { Label("Source code", systemImage: "chevron.left.forwardslash.chevron.right") }
                Link(destination: AppLinks.license) { Label("GNU General Public License v3.0", systemImage: "doc.text") }
                NavigationLink { AcknowledgementsView() } label: { Label("Acknowledgements", systemImage: "heart.text.square") }
            } header: { Text("Free and open source") }
            Section {
                Text("Inspired by **AKS-Labs/CloudGallery** and **Whitehole**, earlier projects that back up photos to Telegram.")
                Text("Lelvo uses the Telegram API. It isn't made, endorsed or supported by Telegram.")
                    .foregroundStyle(.secondary)
            } header: { Text("Credits") }
        }
        .navigationTitle("About")
    }
}

/// Licenses of the third-party code inside the app.
struct AcknowledgementsView: View {
    private static let mitNotice = """
    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated \
    documentation files (the "Software"), to deal in the Software without restriction, including without limitation \
    the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and \
    to permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions of \
    the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO \
    THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF \
    CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER \
    DEALINGS IN THE SOFTWARE.
    """

    var body: some View {
        List {
            Section {
                ForEach(Acknowledgement.allCases) { a in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(a.name).font(.headline)
                        Text(a.detail).font(.subheadline).foregroundStyle(.secondary)
                        Link("License text", destination: a.url).font(.subheadline)
                    }
                    .padding(.vertical, 2)
                }
            }
            Section("MIT License (TDLibKit, TDLibFramework)") {
                Text(Self.mitNotice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .navigationTitle("Acknowledgements")
    }
}

/// Every library in this Telegram account: rename any, switch to another, or create a new one.
/// The same choice as during sign-in, without signing out.
struct LibrarySettingsView: View {
    @State private var channels: [LibraryService.ChannelChoice] = []
    @State private var loading = false
    @State private var busy: String?
    @State private var alert: GalleryAlert?
    @State private var renaming: LibraryService.ChannelChoice?
    @State private var renameText = ""
    @State private var switching: LibraryService.ChannelChoice?
    @State private var switchPassphrase = ""
    @State private var creating = false
    @State private var newName = ""
    @State private var newEncrypted = false
    @State private var newPassphrase = ""
    @State private var newConfirm = ""
    @State private var newAcknowledged = false
    @State private var newRecoveryKey: RecoveryKey?
    private var env: AppEnvironment { AppEnvironment.shared }

    private var libraries: [LibraryService.ChannelChoice] {
        channels.filter(\.isLibrary).sorted { a, b in (a.id == env.library.chatId ? 0 : 1, a.title) < (b.id == env.library.chatId ? 0 : 1, b.title) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Your photos live in one library at a time. Tap another to switch; nothing is deleted from either.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if loading && libraries.isEmpty {
                    HStack(spacing: 10) { ProgressView(); Text("Looking for your libraries…").foregroundStyle(.secondary) }
                        .padding(.vertical, 20)
                }
                ForEach(libraries) { c in
                    let current = c.id == env.library.chatId
                    LibraryCard(title: c.title, encrypted: c.encrypted, selected: current, badge: current ? "CURRENT" : nil,
                                onRename: { renameText = c.title; renaming = c })
                        .onTapGesture {
                            guard !current else { return }
                            Haptics.tap()
                            switchPassphrase = ""
                            switching = c
                        }
                        .contextMenu {
                            Button { renameText = c.title; renaming = c } label: { Label("Rename", systemImage: "pencil") }
                            if !current {
                                Button { switchPassphrase = ""; switching = c } label: { Label("Switch to this library", systemImage: "arrow.left.arrow.right") }
                            }
                        }
                }
                Button { rescan() } label: {
                    Label("Re-scan the current library from Telegram", systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline)
                }
                .padding(.top, 4)
                if env.library.isEncrypted {
                    NavigationLink { EncryptionSettingsView() } label: {
                        Label(env.library.needsHeaderUpgrade ? "Add a recovery key" : "Passphrase and recovery key", systemImage: "key.horizontal")
                            .font(.subheadline)
                    }
                }
                Button {
                    newName = ""; newEncrypted = false; newPassphrase = ""; newConfirm = ""; newAcknowledged = false
                    creating = true
                } label: {
                    Label("New library", systemImage: "plus").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 16))
                .padding(.top, 6)
            }
            .padding(16)
        }
        .navigationTitle("Libraries")
        .refreshable { await load() }
        .disabled(busy != nil)
        .overlay {
            if let busy {
                ProgressView(busy).padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .task { await load() }
        .sheet(item: Binding(get: { newRecoveryKey.map { IdentifiedKey(key: $0) } }, set: { newRecoveryKey = $0?.key })) { k in
            NavigationStack { RecoveryKeyView(key: k.key) { newRecoveryKey = nil }.navigationTitle("Recovery key").inlineNavigationTitle() }
                .interactiveDismissDisabled()
        }
        .alert(item: $alert) { a in Alert(title: Text(a.title), message: Text(a.message)) }
        .alert("Rename library", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") { if let c = renaming { rename(c, to: renameText) }; renaming = nil }
        } message: { Text("Only the name changes. Your photos stay where they are.") }
        .sheet(item: $switching) { c in switchSheet(c) }
        .sheet(isPresented: $creating) { createSheet }
    }

    private func switchSheet(_ c: LibraryService.ChannelChoice) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                LibraryCard(title: c.title, encrypted: c.encrypted, selected: true)
                Text("Lelvo loads this library from Telegram and links your \(Device.name) photos to it. Backups then go here.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if c.encrypted {
                    OnboardingField(placeholder: "Passphrase", text: $switchPassphrase, secure: true, content: .password, autofocus: true)
                }
                Spacer()
                PrimaryCapsuleButton(title: "Switch to “\(c.title)”", enabled: !c.encrypted || !switchPassphrase.isEmpty) {
                    switchTo(c, passphrase: c.encrypted ? switchPassphrase : nil)
                }
            }
            .padding(20)
            .navigationTitle("Switch library")
            .inlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { switching = nil } } }
        }
        .presentationDetents([.medium, .large])
    }

    private var createSheet: some View {
        let problem = EncryptionChoice.problem(encrypted: newEncrypted, passphrase: newPassphrase, confirm: newConfirm, acknowledged: newAcknowledged)
        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("A new, empty library in your Telegram. Your current library stays as it is.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    OnboardingField(placeholder: "Library name", text: $newName, autofocus: true)
                    EncryptionChoice(encrypted: $newEncrypted, passphrase: $newPassphrase, confirm: $newConfirm, acknowledged: $newAcknowledged)
                }
                .padding(20)
            }
            .safeAreaInset(edge: .bottom) {
                PrimaryCapsuleButton(title: "Create and switch",
                                     enabled: problem == nil && !newName.trimmingCharacters(in: .whitespaces).isEmpty) { create() }
                    .padding(20)
            }
            .navigationTitle("New library")
            .inlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { creating = false } } }
        }
    }

    private func load() async {
        loading = true
        channels = (try? await env.library.candidateChannels()) ?? channels
        loading = false
    }

    private func rescan() {
        Task {
            busy = "Re-scanning…"
            defer { busy = nil }
            do {
                let s = try await env.library.scan(full: true)
                env.engine.relinkRestoredItems()
                alert = GalleryAlert(title: "Library re-scanned",
                                     message: "\(s.items) items found\(s.incomplete > 0 ? ", \(s.incomplete) incomplete (tap Retry on the Backup tab)" : "")\(s.orphans.isEmpty ? "" : ", \(s.orphans.count) duplicate uploads (see Backup → Duplicates)").")
            } catch { alert = GalleryAlert(title: "Couldn't re-scan", message: error.localizedDescription) }
        }
    }

    private func rename(_ c: LibraryService.ChannelChoice, to title: String) {
        Task {
            busy = "Renaming…"
            defer { busy = nil }
            do {
                try await env.library.rename(chatId: c.id, to: title)
                Haptics.success()
                await load()
            } catch { alert = GalleryAlert(title: "Couldn't rename", message: error.localizedDescription) }
        }
    }

    private func switchTo(_ c: LibraryService.ChannelChoice, passphrase: String?) {
        switching = nil
        Task {
            busy = "Switching to \(c.title)…"
            defer { busy = nil }
            do {
                try await env.switchLibrary(to: c.id, passphrase: passphrase)
                Haptics.success()
                await load()
            } catch {
                Haptics.error()
                alert = GalleryAlert(title: "Couldn't switch", message: error.localizedDescription)
                await load()
            }
        }
    }

    private func create() {
        let title = String(newName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
        let passphrase = newEncrypted ? newPassphrase : nil
        creating = false
        Task {
            busy = "Creating “\(title)”…"
            defer { busy = nil }
            do {
                newRecoveryKey = try await env.createLibraryAndSwitch(title: title, passphrase: passphrase)
                Haptics.success()
                await load()
            } catch {
                Haptics.error()
                alert = GalleryAlert(title: "Couldn't create the library", message: error.localizedDescription)
            }
        }
    }
}

/// "Download a copy of your library": every backed-up item into a folder the user picks in Files
/// (iPhone, iCloud Drive, or an external drive), as Year/Month/filename. Encrypted items are decrypted.
/// Resumable: files already there with the right size are skipped.
struct ExportLibraryView: View {
    @State private var picking = false
    @State private var running: Task<Void, Never>?
    @State private var done = 0
    @State private var skipped = 0
    @State private var failed: [String] = []
    @State private var total = 0
    @State private var current = ""
    @State private var finished = false
    private var env: AppEnvironment { AppEnvironment.shared }

    var body: some View {
        Form {
            Section {
                Label("Originals with their real names, plus edited versions and Live Photo videos.", systemImage: "doc.on.doc")
                Label("Encrypted items are decrypted, so the copy opens anywhere.", systemImage: "lock.open")
                Label("Pick a folder on this \(Device.name), iCloud Drive, or a USB drive or SSD.", systemImage: "externaldrive")
                Label("Interrupted? Run it again: finished files are skipped.", systemImage: "arrow.clockwise")
            } footer: {
                Text("Make sure the destination has enough free space for your whole library.")
            }
            .font(.subheadline)

            Section {
                if running != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: Double(done + skipped + failed.count), total: Double(max(total, 1)))
                        Text("\(done + skipped + failed.count) of \(total)").font(.subheadline.monospacedDigit())
                        Text(current).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Button("Stop", role: .destructive) { running?.cancel() }
                } else {
                    Button { picking = true } label: { Label("Choose a folder and download", systemImage: "square.and.arrow.down.on.square") }
                }
                if finished {
                    Label("\(done) downloaded, \(skipped) already there\(failed.isEmpty ? "" : ", \(failed.count) failed")",
                          systemImage: failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(failed.isEmpty ? .green : .orange)
                    ForEach(failed.prefix(20), id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .navigationTitle("Download a copy")
        #if os(iOS)
        .sheet(isPresented: $picking) {
            FolderPicker { url in start(url) }.ignoresSafeArea()
        }
        #else
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { start(url) }
        }
        #endif
        .onDisappear { running?.cancel() }
    }

    private func start(_ folder: URL) {
        finished = false
        done = 0; skipped = 0; failed = []
        let items = ((try? env.store.items(status: .backedUp)) ?? []).filter(\.isViewableFromCloud)
        total = items.count
        running = Task {
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            #else
            let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Downloading a copy of the library")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            #endif
            let access = folder.startAccessingSecurityScopedResource()
            defer { if access { folder.stopAccessingSecurityScopedResource() } }
            let fm = FileManager.default
            let calendar = Calendar(identifier: .gregorian)
            for item in items {
                if Task.isCancelled { break }
                let date = item.creationDate ?? Date(timeIntervalSince1970: 0)
                let c = calendar.dateComponents([.year, .month], from: date)
                let dir = folder.appendingPathComponent(String(format: "%04d/%02d", c.year ?? 1970, c.month ?? 1), isDirectory: true)
                current = item.filename
                do {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    var roles: [(String, String, Int64)] = [("o", item.filename, item.fileSize)]
                    if item.kind == .livePhoto, !item.parts("pv").isEmpty {
                        roles.append(("pv", item.pairedVideoFilename ?? "\((item.filename as NSString).deletingPathExtension).MOV", item.pairedVideoSize ?? 0))
                    }
                    if item.hasEdit == true, !item.parts("e").isEmpty {
                        let base = (item.filename as NSString).deletingPathExtension
                        let ext = ((item.editedFilename ?? item.filename) as NSString).pathExtension
                        roles.append(("e", "\(base) (edited).\(ext)", item.editedSize ?? 0))
                    }
                    var wroteAny = false
                    for (role, name, size) in roles {
                        let dest = Self.uniqueURL(dir.appendingPathComponent(name.sanitizedFilename), itemId: item.id, expectedSize: size)
                        if let existing = try? fm.attributesOfItem(atPath: dest.path)[.size] as? NSNumber, size > 0, existing.int64Value == size { continue }
                        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                        try await env.reader.download(item, role: role, to: tmp, evict: true)
                        try? fm.removeItem(at: dest)
                        try fm.moveItem(at: tmp, to: dest)
                        try? fm.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: dest.path)
                        wroteAny = true
                    }
                    if wroteAny { done += 1 } else { skipped += 1 }
                } catch is CancellationError {
                    break
                } catch {
                    failed.append("\(item.filename): \(error.localizedDescription)")
                }
            }
            appLog("Export finished: \(done) downloaded, \(skipped) skipped, \(failed.count) failed")
            finished = true
            running = nil
        }
    }

    /// Same name, different item (e.g. two IMG_0001.HEIC from different years in one month folder): add a suffix.
    private static func uniqueURL(_ url: URL, itemId: String, expectedSize: Int64) -> URL {
        let fm = FileManager.default
        guard let existing = try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
              existing.int64Value != expectedSize else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent()
            .appendingPathComponent("\(base)-\(itemId.prefix(6))")
            .appendingPathExtension(url.pathExtension)
    }
}

#if os(iOS)
/// Files folder picker (any location the user can write to, including external drives).
private struct FolderPicker: UIViewControllerRepresentable {
    let picked: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(picked: picked) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let picked: (URL) -> Void
        init(picked: @escaping (URL) -> Void) { self.picked = picked }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { picked(url) }
        }
    }
}
#endif

/// What gets backed up, and when (moved off the main Settings page).
struct BackupOptionsView: View {
    @AppStorage(Prefs.Key.wifiOnly) private var wifiOnly = true
    @AppStorage(Prefs.Key.chargingOnly) private var chargingOnly = false
    @AppStorage(Prefs.Key.mediaFilter) private var mediaFilter = Prefs.MediaFilter.all.rawValue
    @AppStorage(Prefs.Key.includeScreenshots) private var includeScreenshots = true
    @AppStorage(Prefs.Key.includeHidden) private var includeHidden = false
    @AppStorage(Prefs.Key.dateFromEnabled) private var dateFromEnabled = false
    @AppStorage(Prefs.Key.dateFrom) private var dateFrom: Double = Date().addingTimeInterval(-365 * 86400).timeIntervalSince1970
    @AppStorage(Prefs.Key.streamingCopies) private var streamingCopies = true
    @AppStorage(Prefs.Key.videoQuality) private var videoQuality = VideoQualityPreference.automatic.rawValue

    var body: some View {
        Form {
            Section {
                Picker("Back up", selection: $mediaFilter) {
                    ForEach(Prefs.MediaFilter.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Include screenshots", isOn: $includeScreenshots)
                Toggle("Include hidden photos", isOn: $includeHidden)
                NavigationLink("Albums") { AlbumPickerView() }
                Toggle("Only photos taken after a date", isOn: $dateFromEnabled)
                if dateFromEnabled {
                    DatePicker("From", selection: Binding(get: { Date(timeIntervalSince1970: dateFrom) },
                                                          set: { dateFrom = $0.timeIntervalSince1970 }),
                               displayedComponents: .date)
                }
            } header: { Text("What Back up now includes") } footer: {
                Text("Hidden photos are never shown in Lelvo. If you save them back to Photos, they stay hidden.")
            }

            Section {
                Toggle("Wi-Fi only", isOn: $wifiOnly)
                Toggle("Only while charging", isOn: $chargingOnly)
            } header: { Text("When to upload") } footer: {
                Text("Wi-Fi only also pauses on personal hotspots and Low Data Mode.")
            }

            Section {
                Toggle("Make fast versions of videos", isOn: $streamingCopies)
                Picker("Play cloud videos", selection: $videoQuality) {
                    Text("Automatic").tag(VideoQualityPreference.automatic.rawValue)
                    Text("Original Quality").tag(VideoQualityPreference.original.rawValue)
                }
            } header: { Text("Videos") } footer: {
                Text("A fast version is a small copy (about a tenth of the size) made while a video is backed up, so it plays at once from your Telegram library. The original is always kept. Automatic plays the fast version when the connection is too slow for the original; you can switch in the video at any time.")
            }
        }
        .navigationTitle("Backup options")
    }
}

/// Cache sizes and clearing (moved off the main Settings page).
struct StorageSettingsView: View {
    @AppStorage(Prefs.Key.cacheCapMB) private var cacheCapMB = 1000
    @AppStorage(Prefs.Key.thumbnailCacheMB) private var thumbnailCacheMB = 300
    @State private var usage: CloudMediaService.CacheUsage?
    private var env: AppEnvironment { AppEnvironment.shared }

    var body: some View {
        Form {
            Section {
                LabeledContent("Thumbnails", value: usage.map { Format.bytes($0.thumbnails) } ?? "…")
                LabeledContent("Viewed photos", value: usage.map { Format.bytes($0.originals) } ?? "…")
                LabeledContent("Videos & Telegram files", value: usage.map { Format.bytes($0.telegram) } ?? "…")
                Button("Clear", role: .destructive) {
                    Task {
                        await env.media.clearCaches()
                        refresh()
                        Haptics.success()
                    }
                }
            } header: { Text("Used on this \(Device.name)") } footer: {
                Text("Previews of cloud items you've viewed, kept so they open instantly next time. Clearing never touches your photos or your backup.")
            }
            Section {
                Picker("Viewed photos & videos", selection: $cacheCapMB) {
                    ForEach([250, 500, 1000, 2000, 5000], id: \.self) { mb in Text(mb >= 1000 ? "\(mb / 1000) GB" : "\(mb) MB").tag(mb) }
                }
                Picker("Thumbnails", selection: $thumbnailCacheMB) {
                    ForEach([100, 300, 600, 1000], id: \.self) { mb in Text(mb >= 1000 ? "1 GB" : "\(mb) MB").tag(mb) }
                }
            } header: { Text("Limits") } footer: {
                Text("The oldest previews are removed automatically past these limits.")
            }
        }
        .navigationTitle("Storage")
        .task { refresh() }
        .onChange(of: cacheCapMB) { _, _ in Task { await env.enforceCacheLimits(); refresh() } }
        .onChange(of: thumbnailCacheMB) { _, _ in Task { await env.enforceCacheLimits(); refresh() } }
    }

    private func refresh() {
        Task.detached { let u = AppEnvironment.shared.media.cacheUsage; await MainActor.run { usage = u } }
    }
}
