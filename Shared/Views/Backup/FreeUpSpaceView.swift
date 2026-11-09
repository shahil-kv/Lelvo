import SwiftUI
import Photos
import LelvoCore

struct FreeUpSpaceView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var candidates: [MediaItem] = []
    @State private var verified: [MediaItem] = []
    @State private var verifying = false
    @State private var checked = 0
    @State private var cancelFlag = CancelFlag()
    @State private var deleting = false
    @State private var result: GalleryAlert?
    /// What the last removal freed, shown in place (rolling up) instead of in an alert.
    @State private var freed: (count: Int, bytes: Int64)?
    @State private var shownBytes: Int64 = 0
    @State private var burst: CatchingMark.Burst?
    /// The list takes a while on a big library (each photo is looked up in Photos). The button works during it.
    @State private var loadTask: Task<Void, Never>?

    private var service: FreeUpSpaceService { AppEnvironment.shared.freeUpSpace }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    CatchingMark(status: freed == nil ? .idle : .complete, width: 84, burst: burst)
                        .padding(.top, 6)
                    if let freed {
                        Text(Format.bytes(shownBytes))
                            .font(.system(.largeTitle, design: .rounded, weight: .bold).monospacedDigit())
                            .foregroundStyle(.tint)
                            .contentTransition(.numericText(value: Double(shownBytes)))
                        Text("Freed from \(freed.count.formatted()) item\(freed.count == 1 ? "" : "s"). They're still in your Telegram library and in Lelvo. Empty Recently Deleted in Photos to get the space back now.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    } else {
                        Text("Remove photos and videos from this \(Device.name) that are already safely backed up, to get storage back. They stay in Lelvo, and you can save any of them back anytime.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
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
        let toRemove = verified
        // Thumbnails first: once iOS has deleted the photos, they can't be drawn for the animation any more.
        let preview = await previewImages(toRemove)
        do {
            let deleted = try await service.delete(toRemove)
            guard !deleted.isEmpty else {
                result = GalleryAlert(title: "Nothing was removed", message: "These items changed since the check. Check again and try once more.")
                verified = []
                load()
                return
            }
            let gone = toRemove.filter { $0.localIdentifier.map(deleted.contains) ?? false }
            Haptics.success()
            showFreed(count: gone.count, bytes: FreeUpSpaceService.bytes(of: gone),
                      images: preview.filter { deleted.contains($0.id) }.map(\.image))
            verified = []
            load()
        } catch let error as NSError where error.domain == PHPhotosErrorDomain && error.code == PHPhotosError.userCancelled.rawValue {
            // Cancelled in iOS's own prompt: nothing happened, nothing to say.
        } catch {
            Haptics.error()
            result = GalleryAlert(title: "Nothing was deleted", message: error.localizedDescription)
        }
    }

    /// Counts the freed space up over about 0.7 s, while the photos fly into the cloud.
    private func showFreed(count: Int, bytes: Int64, images: [PlatformImage]) {
        shownBytes = 0
        withAnimation(Motion.standard) { freed = (count, bytes) }
        if !images.isEmpty { burst = CatchingMark.Burst(images: images) }
        Task {
            let steps = 14
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(50))
                let eased = 1 - pow(1 - Double(step) / Double(steps), 3)
                withAnimation(Motion.tap) { shownBytes = Int64(Double(bytes) * eased) }
            }
        }
    }

    /// Small images of the first few items, loaded off the main actor. Skipped when the animation won't play.
    private func previewImages(_ items: [MediaItem]) async -> [(id: String, image: PlatformImage)] {
        guard Motion.decorative(reduceMotion: reduceMotion) else { return [] }
        let ids = items.prefix(8).compactMap(\.localIdentifier)
        return await Task.detached(priority: .userInitiated) {
            let photos = AppEnvironment.shared.photos
            var out: [(id: String, image: PlatformImage)] = []
            for id in ids {
                guard let asset = photos.asset(localIdentifier: id),
                      let image = await photos.image(for: asset, targetSize: CGSize(width: 120, height: 120), mode: .fastFormat) else { continue }
                out.append((id, image))
            }
            return out
        }.value
    }
}
