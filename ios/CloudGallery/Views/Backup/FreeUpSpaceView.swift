import SwiftUI
import CloudGalleryCore

struct FreeUpSpaceView: View {
    @State private var candidates: [MediaItem] = []
    @State private var verified: [MediaItem] = []
    @State private var verifying = false
    @State private var checked = 0
    @State private var cancelFlag = CancelFlag()
    @State private var deleting = false
    @State private var result: GalleryAlert?

    private var service: FreeUpSpaceService { AppEnvironment.shared.freeUpSpace }

    var body: some View {
        Form {
            Section {
                Label {
                    Text("Remove photos and videos from this \(Device.name) that are already safely backed up, to get storage back. They stay in CloudGallery, and you can save any of them back anytime.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "internaldrive.fill").foregroundStyle(.blue)
                }
            }

            Section {
                LabeledContent("Backed up and on this \(Device.name)", value: candidates.count.formatted())
                LabeledContent("Checked, safe to remove", value: verified.count.formatted())
                LabeledContent("Space you can free", value: Format.bytes(FreeUpSpaceService.bytes(of: verified)))
            } footer: {
                Text("Before anything is offered, CloudGallery checks in Telegram that every part of it is really there. Items not fully backed up, or edited after their backup, are never offered.")
            }

            Section {
                if verifying {
                    ProgressView(value: Double(checked), total: Double(max(candidates.count, 1))) {
                        Text("Checking \(checked) of \(candidates.count)…")
                    }
                }
                actions
            } footer: {
                Text("\(Device.name == "Mac" ? "macOS" : "iOS") asks you to confirm. Removed items move to “Recently Deleted” in Photos for 30 days; empty it to get the space back right away. They stay in CloudGallery as cloud items.")
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
                    .disabled(candidates.isEmpty)
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
            Button { Task { await verify() } } label: { Label("Check what's safe to remove", systemImage: "checkmark.shield") }
                .disabled(candidates.isEmpty)
        }
        Button(role: .destructive) { Task { await delete() } } label: { Label(removeTitle, systemImage: "trash") }
            .disabled(verified.isEmpty || verifying || deleting)
        #endif
    }

    private func load() {
        Task.detached {
            let c = AppEnvironment.shared.freeUpSpace.candidates()
            let v = c.filter { AppEnvironment.shared.freeUpSpace.isFreshlyVerified($0) }
            await MainActor.run {
                candidates = c
                verified = v
            }
        }
    }

    private func verify() async {
        cancelFlag = CancelFlag()
        verifying = true
        checked = 0
        defer { verifying = false }
        var passed: [MediaItem] = []
        for item in candidates {
            if cancelFlag.isCancelled { break }
            var ok = service.isFreshlyVerified(item)
            if !ok { ok = await service.verify(item) }
            if ok {
                passed.append((try? AppEnvironment.shared.store.item(id: item.id)) ?? item)
            }
            checked += 1
        }
        verified = passed
        Haptics.success()
    }

    private func delete() async {
        deleting = true
        defer { deleting = false }
        do {
            let count = try await service.delete(verified)
            Haptics.success()
            result = GalleryAlert(title: "Removed \(count) item(s) from \(Device.name)",
                                  message: "They are still in your Telegram backup and in CloudGallery. Open Photos → Recently Deleted and choose Delete All to free the space now.")
            load()
        } catch {
            result = GalleryAlert(title: "Nothing was deleted", message: error.localizedDescription)
        }
    }
}
