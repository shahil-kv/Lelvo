import SwiftUI
import CloudGalleryCore

struct FreeUpSpaceView: View {
    @AppStorage(Prefs.Key.allowFreeUpSpace) private var allowed = false
    @State private var candidates: [MediaItem] = []
    @State private var verified: [MediaItem] = []
    @State private var verifying = false
    @State private var checked = 0
    @State private var cancelFlag = CancelFlag()
    @State private var deleting = false
    @State private var result: GalleryAlert?

    private var service: FreeUpSpaceService { AppEnvironment.shared.freeUpSpace }

    var body: some View {
        List {
            if !allowed {
                Section {
                    EmptyStateView(systemImage: "lock.shield", title: "Free Up Space is off",
                                   message: "For safety this is disabled until you turn it on. When enabled, CloudGallery only offers to delete photos it has verified are in your Telegram channel and can be downloaded again.")
                    Toggle("Allow freeing up space", isOn: $allowed)
                }
            } else {
                Section {
                    LabeledContent("Backed up and on this iPhone", value: "\(candidates.count)")
                    LabeledContent("Verified safe to remove", value: "\(verified.count)")
                    LabeledContent("Space you can free", value: Format.bytes(FreeUpSpaceService.bytes(of: verified)))
                } footer: {
                    Text("Verification checks each Telegram message still exists and re-fetches the file to compare its size. Files over 20 MB, failed or unverified items are never offered.")
                }

                Section {
                    if verifying {
                        ProgressView(value: Double(checked), total: Double(max(candidates.count, 1))) {
                            Text("Verifying \(checked) of \(candidates.count)…")
                        }
                        Button("Stop", role: .cancel) { cancelFlag.cancel() }
                    } else {
                        Button { Task { await verify() } } label: {
                            Label("Verify backups", systemImage: "checkmark.shield")
                        }
                        .disabled(candidates.isEmpty)
                    }
                    Button(role: .destructive) { Task { await delete() } } label: {
                        Label(deleting ? "Deleting…" : "Delete \(verified.count) verified item(s) from iPhone", systemImage: "trash")
                    }
                    .disabled(verified.isEmpty || verifying || deleting)
                } footer: {
                    Text("iOS will ask you to confirm. Deleted items stay in CloudGallery as cloud items. Afterwards, empty “Recently Deleted” in the Photos app to actually free the space.")
                }

                if !verified.isEmpty {
                    Section("Verified items") {
                        ForEach(verified.prefix(200)) { item in
                            HStack {
                                Text(item.filename).lineLimit(1)
                                Spacer()
                                Text(Format.bytes(item.fileSize + (item.pairedVideoSize ?? 0))).foregroundStyle(.secondary)
                            }
                            .font(.footnote)
                        }
                        if verified.count > 200 { Text("…and \(verified.count - 200) more").font(.footnote).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .navigationTitle("Free Up Space")
        .onAppear(perform: load)
        .onChange(of: allowed) { _, _ in load() }
        .onDisappear { cancelFlag.cancel() }
        .alert(item: $result) { a in Alert(title: Text(a.title), message: Text(a.message)) }
    }

    private func load() {
        guard allowed else { return }
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
        var ok: [MediaItem] = []
        for item in candidates {
            if cancelFlag.isCancelled { break }
            if service.isFreshlyVerified(item) || (await service.verify(item)) {
                ok.append((try? AppEnvironment.shared.store.item(id: item.id)) ?? item)
            }
            checked += 1
        }
        verified = ok
        Haptics.success()
    }

    private func delete() async {
        deleting = true
        defer { deleting = false }
        do {
            let count = try await service.delete(verified)
            Haptics.success()
            result = GalleryAlert(title: "Removed \(count) item(s) from iPhone",
                                  message: "They are still in your Telegram backup and in CloudGallery. Open Photos → Albums → Recently Deleted and choose Delete All to free the space now.")
            load()
        } catch {
            result = GalleryAlert(title: "Nothing was deleted", message: error.localizedDescription)
        }
    }
}
