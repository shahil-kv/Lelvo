import SwiftUI
import LelvoCore

struct FreeUpSpaceView: View {
    @State private var candidates: [MediaItem] = []
    @State private var verified: [MediaItem] = []
    @State private var verifying = false
    @State private var checked = 0
    @State private var cancelFlag = CancelFlag()
    @State private var deleting = false
    @State private var result: GalleryAlert?
    /// The list takes a while on a big library (each photo is looked up in Photos). The button works during it.
    @State private var loadTask: Task<Void, Never>?

    private var service: FreeUpSpaceService { AppEnvironment.shared.freeUpSpace }

    var body: some View {
        Form {
            Section {
                Label {
                    Text("Remove photos and videos from this \(Device.name) that are already safely backed up, to get storage back. They stay in Lelvo, and you can save any of them back anytime.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "internaldrive.fill").foregroundStyle(.tint)
                }
            }

            Section {
                LabeledContent("Backed up and on this \(Device.name)", value: candidates.count.formatted())
                LabeledContent("Checked, safe to remove", value: verified.count.formatted())
                LabeledContent("Space you can free", value: Format.bytes(FreeUpSpaceService.bytes(of: verified)))
            } footer: {
                Text("Before anything is offered, Lelvo checks in Telegram that every part of it is really there. Items not fully backed up, or edited after their backup, are never offered.")
            }

            Section {
                if verifying {
                    ProgressView(value: Double(checked), total: Double(max(candidates.count, 1))) {
                        Text(candidates.isEmpty ? "Finding your backed up photos…" : "Checking \(checked) of \(candidates.count)…")
                    }
                }
                actions
            } footer: {
                Text("\(Device.name == "Mac" ? "macOS" : "iOS") asks you to confirm. Removed items move to “Recently Deleted” in Photos for 30 days; empty it to get the space back right away. They stay in Lelvo as cloud items.")
            }

            if !verified.isEmpty {
                Section("Safe to remove") {
                    ForEach(verified.prefix(200)) { item in
                        LabeledContent(item.filename, value: Format.bytes(item.fileSize + (item.pairedVideoSize ?? 0)))
                    }
                    if verified.count > 200 { Text("…and \(verified.count - 200) more").foregroundStyle(.secondary) }
                }
            }
        }
        .platformGroupedForm()
        .navigationTitle("Free Up Space")
        .onAppear(perform: load)
        .onDisappear { cancelFlag.cancel() }
        .alert(item: $result) { a in Alert(title: Text(a.title), message: Text(a.message)) }
    }

    @ViewBuilder private var actions: some View {
        let removeTitle = deleting ? "Removing…" : "Remove \(verified.count) from \(Device.name) (\(Format.bytes(FreeUpSpaceService.bytes(of: verified))))"
        #if os(macOS)
        HStack {
            Spacer()
            if verifying {
                Button("Stop") { cancelFlag.cancel() }
            } else {
                Button("Check What's Safe to Remove") { Task { await verify() } }
            }
            if !verified.isEmpty {
                Button(removeTitle, role: .destructive) { Task { await delete() } }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(verifying || deleting)
            }
        }
        #else
        if verifying {
            Button("Stop", role: .cancel) { cancelFlag.cancel() }
        } else {
            Button {
                Haptics.tap()
                Task { await verify() }
            } label: { Label("Check what's safe to remove", systemImage: "checkmark.shield") }
        }
        Button(role: .destructive) { Task { await delete() } } label: { Label(removeTitle, systemImage: "trash") }
            .disabled(verified.isEmpty || verifying || deleting)
        #endif
    }

    private func load() {
        loadTask = Task {
            let (c, v) = await Task.detached {
                let service: FreeUpSpaceService = AppEnvironment.shared.freeUpSpace
                let c = service.candidates()
                return (c, c.filter { service.isFreshlyVerified($0) })
            }.value
            // A check already running owns the list of what passed.
            candidates = c
            if !verifying { verified = v }
        }
    }

    private func verify() async {
        cancelFlag = CancelFlag()
        let flag = cancelFlag
        verifying = true
        checked = 0
        defer { verifying = false }
        await loadTask?.value
        let toast = ToastCenter.shared
        guard !candidates.isEmpty else {
            verified = []
            toast.show(.info, "Nothing to check yet", detail: "Only photos backed up and still on this \(Device.name) can be removed.")
            return
        }
        // Offline, each photo would wait its own 20 seconds, and the bar would look stuck.
        if !DemoMode.isActive {
            do { try await AppEnvironment.shared.td.waitUntilReady(timeout: 20) } catch {
                toast.show(.failure, "Couldn't reach Telegram", detail: "Check your connection and try again.", seconds: 5)
                Haptics.error()
                return
            }
        }
        var passed: [MediaItem] = []
        for item in candidates {
            if flag.isCancelled { break }
            let current: MediaItem? = await Task.detached {
                let service: FreeUpSpaceService = AppEnvironment.shared.freeUpSpace
                var ok = service.isFreshlyVerified(item)
                if !ok { ok = await service.verify(item) }
                return ok ? ((try? AppEnvironment.shared.store.item(id: item.id)) ?? item) : nil
            }.value
            if let current { passed.append(current) }
            checked += 1
        }
        verified = passed
        if flag.isCancelled {
            toast.show(.info, "Check stopped", detail: "\(passed.count.formatted()) of \(checked.formatted()) checked are safe to remove.")
            return
        }
        Haptics.success()
        let unsafe = candidates.count - passed.count
        if passed.isEmpty {
            toast.show(.failure, "Nothing is safe to remove", detail: "\(unsafe.formatted()) couldn't be confirmed in your Telegram library.", seconds: 5)
        } else {
            toast.show(.success, "\(passed.count.formatted()) safe to remove",
                       detail: unsafe > 0 ? "\(unsafe.formatted()) couldn't be confirmed, so they stay." : "Telegram has every part of them.")
        }
    }

    private func delete() async {
        deleting = true
        defer { deleting = false }
        do {
            let count = try await service.delete(verified)
            guard count > 0 else {
                result = GalleryAlert(title: "Nothing was removed", message: "These items changed since the check. Check again and try once more.")
                verified = []
                load()
                return
            }
            Haptics.success()
            result = GalleryAlert(title: "Removed \(count) item(s) from \(Device.name)",
                                  message: "They are still in your Telegram backup and in Lelvo. Open Photos → Recently Deleted and choose Delete All to free the space now.")
            load()
        } catch {
            result = GalleryAlert(title: "Nothing was deleted", message: error.localizedDescription)
        }
    }
}
