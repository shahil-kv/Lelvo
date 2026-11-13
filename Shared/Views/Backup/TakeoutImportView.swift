import SwiftUI
import LelvoCore

/// The import, one step at a time: choose the zips, start, watch it go, finish a zip. Only what can be acted on now
/// is shown. A finished zip is deleted only after this screen asks, and only once everything in it is settled.
struct TakeoutImportView: View {
    @ObservedObject private var importer: TakeoutImporter
    @ObservedObject private var activity = BackupActivity.shared
    @StateObject private var model = TakeoutImportModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var space: (needed: Int64, free: Int64)?
    @State private var addError: String?
    @State private var deleteError: String?
    @State private var deleteTarget: TakeoutImportModel.SourceRow?
    @State private var deleteID: String?
    @State private var deleteNotMedia: [String] = []
    @State private var deleteSeparate: [String] = []
    @State private var fixtureLoading = false

    /// Files the guide already picked. `fresh` clears a finished import first, so a new export starts clean.
    private let pending: [URL]
    private let fresh: Bool
    @State private var pendingHandled = false

    init(pending: [URL] = [], fresh: Bool = false) {
        importer = AppEnvironment.shared.importer
        self.pending = pending
        self.fresh = fresh
    }

    /// What the screen is about right now. Each step shows its own summary and one main button.
    private enum Step: Equatable {
        case empty, reading, ready, resumable, importing, finished
    }

    var body: some View {
        withDialogs(content
            .onAppear {
                captureSpace()
                reload()
                Task { await loadFixtureIfNeeded() }
                if !pending.isEmpty, !pendingHandled {
                    pendingHandled = true
                    Task {
                        if fresh { await importer.clear() }
                        await addAccessing(pending)
                    }
                }
            }
            .onChange(of: importer.state) { _, _ in
                captureSpace()
                reload()
            }
            .onChange(of: importer.notMedia) { _, _ in reload() }
            .onChange(of: importer.counts) { _, _ in reload() })
    }

    private var content: some View {
        Form {
            if let banner { bannerSection(banner) }
            summarySection
            mainActionSection
            if step == .finished, !model.importedIds.isEmpty { showImportedSection }
            if step != .empty { filesSection }
            if showsAllFiles { allFilesSection }
            if showsNeedALook { needALookSection }
        }
        .platformGroupedForm()
        .navigationTitle("Import")
        .animation(Motion.adaptive(Motion.standard, reduceMotion: reduceMotion), value: step)
        .sensoryFeedback(.success, trigger: finishedAfterImport)
        .navigationDestination(isPresented: $showsImported) {
            ImportedPhotosView(filter: .imported(model.importedIds))
        }
    }

    @State private var showsImported = false

    /// True only once the import itself reaches the end, so opening an already finished import stays quiet.
    @State private var finishedAfterImport = false

    private func withDialogs(_ view: some View) -> some View {
        view
            .onChange(of: step) { old, new in
                if old == .importing, new == .finished { finishedAfterImport = true }
            }
            .alert("Couldn't add these files", isPresented: showAddError) {
                Button("OK", role: .cancel) { addError = nil }
            } message: {
                Text(addError ?? "")
            }
            .confirmationDialog(deleteTitle, isPresented: confirmingDelete, titleVisibility: .visible) {
                Button("Delete zip", role: .destructive) {
                    let id = deleteID
                    deleteID = nil
                    guard let id else { return }
                    Task { await delete(id) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(deleteMessage)
            }
            .alert(deleteError ?? "", isPresented: showDeleteError) {
                Button("OK", role: .cancel) { deleteError = nil }
            }
    }

    // MARK: - State

    private var step: Step {
        switch importer.state {
        case .idle: return model.sources.isEmpty ? .empty : .ready
        case .cataloguing: return .reading
        case .importing: return .importing
        case .finished: return .finished
        case .ready, .paused, .needsSource: return settled > 0 ? .resumable : .ready
        }
    }

    private var isImporting: Bool { step == .importing }
    private var isCataloguing: Bool { step == .reading }

    /// Items in the plan, and how many of them are settled (imported, already in the library or skipped).
    private var total: Int { importer.counts.values.reduce(0, +) }
    private var settled: Int {
        (importer.counts[.done] ?? 0) + (importer.counts[.duplicate] ?? 0) + (importer.counts[.skipped] ?? 0)
    }

    private var spaceIsShort: Bool {
        if case .ready(let needed, let free) = importer.state { return needed > free }
        return false
    }

    private var hasFiles: Bool { !model.sources.isEmpty || model.photos + model.videos > 0 }

    private var showsNextZip: Bool {
        step == .finished || model.sources.contains { $0.finished && $0.kind == "zip" }
    }

    /// Only useful once a zip is done or a photo is waiting for a date from another zip.
    private var showsAllFiles: Bool {
        guard hasFiles, !importer.allFilesAdded else { return false }
        if step == .finished { return true }
        guard step == .ready || step == .resumable else { return false }
        return model.waiting > 0 || model.sources.contains(where: \.finished)
    }

    private var needALookCount: Int { model.failed.count + model.undated.count + model.notImported.count }
    /// Before the import starts, the summary already names files that aren't photos or videos.
    private var showsNeedALook: Bool {
        guard needALookCount > 0 else { return false }
        switch step {
        case .resumable, .finished: return true
        case .ready: return !model.failed.isEmpty || !model.undated.isEmpty
        case .empty, .reading, .importing: return false
        }
    }

    // MARK: - Banner

    private struct Banner {
        var text: String
        var detail: String?
        var chooseAgain = false
    }

    /// One calm banner for anything that stopped the import: no network, no space, a moved zip.
    private var banner: Banner? {
        if case .needsSource(let name) = importer.state {
            return Banner(text: "\(name) is no longer where it was.", detail: "Choose it again to continue.", chooseAgain: true)
        }
        if let message = importer.message {
            return Banner(text: message, detail: isImporting ? "It goes on by itself when it can." : nil)
        }
        if spaceIsShort, let space {
            return Banner(text: "There isn't enough space.",
                          detail: "Free up \(Format.bytes(space.needed - space.free)) or move the zip to a USB drive.")
        }
        return nil
    }

    private func bannerSection(_ banner: Banner) -> some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.title3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(banner.text).fixedSize(horizontal: false, vertical: true)
                    if let detail = banner.detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
            if banner.chooseAgain {
                Button("Choose it again", action: choose)
            }
        }
    }

    // MARK: - Summary

    @ViewBuilder private var summarySection: some View {
        switch step {
        case .empty:
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("Choose the zip files from Google Takeout, or a folder of them.")
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
        case .reading:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Reading the files…")
                }
                .padding(.vertical, 6)
            }
        case .ready:
            Section {
                readySummary.padding(.vertical, 6)
            }
        case .resumable, .importing:
            Section {
                progressSummary.padding(.vertical, 6)
            }
        case .finished:
            Section {
                finishedSummary.padding(.vertical, 8)
            }
        }
    }

    private var readySummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.photos + model.videos == 0 {
                Text("No photos or videos to import.")
                    .font(.headline)
            } else {
                if model.photos > 0 { bigCount(model.photos, model.photos == 1 ? "photo" : "photos", size: .largeTitle) }
                if model.videos > 0 { bigCount(model.videos, model.videos == 1 ? "video" : "videos", size: .title) }
            }
            ForEach(readyNotes, id: \.self) { note in
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The small print, only when it isn't zero.
    private var readyNotes: [String] {
        var notes: [String] = []
        if model.already > 0 {
            notes.append("\(model.already.formatted()) already in your library will be skipped.")
        }
        if model.waiting > 0 {
            notes.append("\(model.waiting.formatted()) are waiting for a date from another zip.")
        }
        if model.notMedia > 0 {
            notes.append(model.notMedia == 1
                ? "1 file isn't a photo or video, so it won't be imported."
                : "\(model.notMedia.formatted()) files aren't photos or videos, so they won't be imported.")
        }
        return notes
    }

    private func bigCount(_ value: Int, _ noun: String, size: Font) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value.formatted())
                .font(size.weight(.bold))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(value)))
            Text(noun)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var progressSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(settled.formatted())
                    .font(.largeTitle.weight(.bold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(settled)))
                Text("of \(total.formatted())")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(settled.formatted()) of \(total.formatted()) imported")
            ProgressView(value: Double(settled), total: Double(max(total, 1)))
                .accessibilityHidden(true)
            if let lane = currentLane {
                Text(lane.total > 0
                     ? "\(lane.name) · \(Format.bytes(lane.sent)) of \(Format.bytes(lane.total))"
                     : lane.name)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if step == .resumable {
                Text("Nothing is lost. Photos already sent stay in your library.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.recent.isEmpty { recentStrip(columns: 6) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var finishedSummary: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: step == .finished)
                .accessibilityHidden(true)
            Text("Import finished")
                .font(.title3.weight(.semibold))
            Text(finishedText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !model.recent.isEmpty { recentStrip(columns: 4) }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// Imported photos keep the date they were taken, so they're usually far down the timeline, not at the top.
    private var showImportedSection: some View {
        Section {
            prominentButton("Show imported photos") { showsImported = true }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        } footer: {
            Text("They're in Photos under the dates they were taken, not at the top.")
        }
    }

    private var finishedText: String {
        let imported = model.importedPhotos + model.importedVideos
        var text = imported == 1
            ? "1 photo or video is in your Telegram library."
            : "\(imported.formatted()) photos and videos are in your Telegram library."
        if model.already > 0 {
            text += " \(model.already.formatted()) \(model.already == 1 ? "was" : "were") already there."
        }
        return text
    }

    /// The photos that just reached your Telegram library, newest first. A new one slides in at the front.
    private func recentStrip(columns: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: columns), spacing: 3) {
            ForEach(model.recent.prefix(columns)) { thumb in
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        Image(platformImage: thumb.image)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(Motion.adaptive(Motion.emphasis, reduceMotion: reduceMotion), value: model.recent.map(\.id))
        .padding(.top, 4)
        .accessibilityHidden(true)
    }

    private var currentLane: BackupActivity.LaneProgress? {
        activity.lanes
            .filter { $0.key.hasPrefix("import-") }
            .sorted { $0.key < $1.key }
            .first?.value
    }

    // MARK: - Main action

    @ViewBuilder private var mainActionSection: some View {
        switch step {
        case .empty:
            Section {
                prominentButton("Choose files", action: choose)
            }
        case .ready, .resumable:
            Section {
                prominentButton(step == .resumable ? "Resume import" : "Start import") { importer.start() }
                    .disabled(spaceIsShort || model.photos + model.videos == 0)
            } footer: {
                Text(startFooter)
            }
        case .importing:
            Section {
                Button { importer.pause() } label: {
                    Text("Pause").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } footer: {
                Text("Keep Lelvo open while it imports. If it stops, it carries on from the same photo.")
            }
        case .reading, .finished:
            EmptyView()
        }
    }

    private var startFooter: String {
        var text = "Keep Lelvo open while it imports."
        if let space, !spaceIsShort {
            text += " Needs \(Format.bytes(space.needed)), \(Format.bytes(space.free)) free."
        }
        return text
    }

    private func prominentButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }

    // MARK: - Files

    private var filesSection: some View {
        Section {
            ForEach(model.sources) { source in
                sourceRow(source)
            }
            Button(showsNextZip ? "Add the next zip" : "Add another zip", action: choose)
                .disabled(isImporting || isCataloguing)
        } header: {
            Text(model.sources.count == 1 ? "File" : "Files")
        }
    }

    private func sourceRow(_ source: TakeoutImportModel.SourceRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: source.kind == "zip" ? "doc.zipper" : "folder")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    if source.bytes > 0 {
                        Text(Format.bytes(source.bytes))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                statusPill(source)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(source.name), \(source.status)")
            if source.finished, source.kind == "zip" {
                Button(role: .destructive) {
                    if isImporting || isCataloguing {
                        deleteError = "Pause the import before deleting a file."
                    } else {
                        prepareDelete(source)
                    }
                } label: {
                    Text("Delete zip · frees \(Format.bytes(source.bytes))")
                }
                .accessibilityLabel("Delete \(source.name). Frees \(Format.bytes(source.bytes)).")
            }
        }
        .padding(.vertical, 2)
    }

    private func statusPill(_ source: TakeoutImportModel.SourceRow) -> some View {
        let color: Color = source.finished ? .green : (source.status == "Choose it again" ? .orange : .accentColor)
        return Text(source.status)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
            .fixedSize()
    }

    private var allFilesSection: some View {
        Section {
            Button("That's all my files") {
                Task { await importer.allFilesAdded() }
            }
        } footer: {
            Text(step == .finished
                 ? "Tap this once every zip from this Google export is imported. Your next import then starts fresh."
                 : "Tap this once every zip from Google is added. Photos still waiting for a date then use the date saved in the file.")
        }
    }

    private var needALookSection: some View {
        Section {
            NavigationLink {
                TakeoutNeedALookView(failed: model.failed, undated: model.undated, notImported: model.notImported,
                                     canRetry: !model.failed.isEmpty) {
                    importer.start()
                }
            } label: {
                HStack {
                    Text(model.failed.isEmpty ? "Details" : "Need a look")
                    Spacer()
                    Text((model.failed.isEmpty ? needALookCount : model.failed.count).formatted())
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(model.failed.isEmpty ? Color.secondary : Color.orange)
                        .monospacedDigit()
                }
            }
            .accessibilityLabel(model.failed.isEmpty
                ? "Details, \(needALookCount) files"
                : "Need a look, \(model.failed.count) files didn't upload")
        }
    }

    // MARK: - Delete

    private var showAddError: Binding<Bool> {
        Binding(get: { addError != nil }, set: { if !$0 { addError = nil } })
    }

    private var confirmingDelete: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    private var showDeleteError: Binding<Bool> {
        Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })
    }

    private var deleteTitle: String {
        "Delete \(deleteTarget?.name ?? "this zip")?"
    }

    /// The question, then every entry in this zip that was not imported as part of a photo or video.
    private var deleteMessage: String {
        var lines = ["Every photo and video in it is in your Telegram library."]
        if !deleteNotMedia.isEmpty {
            lines.append("")
            lines.append("Not a photo or video:")
            lines.append(contentsOf: deleteNotMedia)
        }
        if !deleteSeparate.isEmpty {
            lines.append("")
            lines.append("Imported separately:")
            lines.append(contentsOf: deleteSeparate)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Actions

    private func captureSpace() {
        if case .ready(let needed, let free) = importer.state {
            space = (needed, free)
        }
    }

    private func reload() {
        model.reload(cataloguing: isCataloguing, importing: isImporting, notMedia: importer.notMedia)
    }

    private func choose() {
        #if DEBUG
        if TakeoutFixture.enabled {
            Task { await loadFixtureIfNeeded() }
            return
        }
        #endif
        TakeoutFilePicker.choose { urls in
            Task { await addAccessing(urls) }
        }
    }

    /// Picked files stay readable while they're catalogued; the importer keeps a bookmark for later.
    private func addAccessing(_ urls: [URL]) async {
        let kept = urls.map { (url: $0, accessed: $0.startAccessingSecurityScopedResource()) }
        defer {
            for item in kept where item.accessed { item.url.stopAccessingSecurityScopedResource() }
        }
        await add(kept.map(\.url))
    }

    private func add(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        do {
            try await importer.add(urls: urls)
        } catch {
            addError = error.localizedDescription
        }
    }

    private func prepareDelete(_ source: TakeoutImportModel.SourceRow) {
        let id = source.id
        Task {
            let leftover = await Task.detached { TakeoutImportLists.leftovers(sourceId: id) }.value
            deleteNotMedia = leftover.notMedia
            deleteSeparate = leftover.separate
            deleteID = id
            deleteTarget = source
        }
    }

    private func delete(_ id: String) async {
        do {
            try await importer.deleteSource(id: id)
        } catch {
            deleteError = error.localizedDescription
        }
    }

    /// UI tests have no Takeout on disk. The argument drops any earlier import and loads a tiny folder
    /// through the same add path, off the main actor.
    private func loadFixtureIfNeeded() async {
        #if DEBUG
        guard TakeoutFixture.enabled, !fixtureLoading else { return }
        fixtureLoading = true
        defer { fixtureLoading = false }
        await importer.clear()
        let url: URL
        do {
            url = try await Task.detached { try TakeoutFixture.make() }.value
        } catch {
            addError = error.localizedDescription
            return
        }
        await add([url])
        #endif
    }
}

/// Every file that needs attention, each with one plain reason. Failed ones can be tried again from here.
private struct TakeoutNeedALookView: View {
    var failed: [String]
    var undated: [String]
    var notImported: [String]
    var canRetry: Bool
    var retry: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            if !failed.isEmpty {
                Section {
                    ForEach(Array(failed.enumerated()), id: \.offset) { _, name in Text(name) }
                    if canRetry {
                        Button("Try again") {
                            retry()
                            dismiss()
                        }
                    }
                } header: {
                    Text("Didn't upload")
                } footer: {
                    Text("Lelvo tries these again when you tap Try again or start the import.")
                }
            }
            if !undated.isEmpty {
                Section {
                    ForEach(Array(undated.enumerated()), id: \.offset) { _, name in Text(name) }
                } header: {
                    Text("No date from Google")
                } footer: {
                    Text("These are dated from the file, or from the zip if the file has no date.")
                }
            }
            if !notImported.isEmpty {
                Section {
                    ForEach(Array(notImported.enumerated()), id: \.offset) { _, name in Text(name) }
                } header: {
                    Text("Not a photo or video")
                } footer: {
                    Text("These weren't imported.")
                }
            }
        }
        .platformGroupedForm()
        .navigationTitle(failed.isEmpty ? "Details" : "Need a look")
        .inlineNavigationTitle()
    }
}

/// Names and counts for the import screen. The index is read off the main actor.
@MainActor
private final class TakeoutImportModel: ObservableObject {
    struct SourceRow: Identifiable, Equatable, Sendable {
        var id: String
        var name: String
        var status: String
        var kind: String
        var bytes: Int64
        var finished: Bool
    }

    @Published private(set) var sources: [SourceRow] = []
    @Published private(set) var photos = 0
    @Published private(set) var videos = 0
    @Published private(set) var already = 0
    @Published private(set) var notMedia = 0
    @Published private(set) var waiting = 0
    @Published private(set) var importedPhotos = 0
    @Published private(set) var importedVideos = 0
    @Published private(set) var failed: [String] = []
    @Published private(set) var undated: [String] = []
    @Published private(set) var notImported: [String] = []
    @Published private(set) var loaded = false
    /// The newest imported photos, for the strip under the progress.
    @Published private(set) var recent: [RecentThumb] = []
    /// Every item this import uploaded, for "Show imported photos".
    @Published private(set) var importedIds: Set<String> = []

    struct RecentThumb: Identifiable {
        var id: String
        var image: PlatformImage
    }

    private var generation = 0

    func reload(cataloguing: Bool, importing: Bool, notMedia: Int) {
        generation += 1
        let generation = generation
        Task {
            let snapshot = await Task.detached {
                Self.snapshot(cataloguing: cataloguing, importing: importing, notMedia: notMedia)
            }.value
            guard generation == self.generation else { return }
            sources = snapshot.sources
            photos = snapshot.photos
            videos = snapshot.videos
            already = snapshot.already
            self.notMedia = snapshot.notMedia
            waiting = snapshot.waiting
            importedPhotos = snapshot.importedPhotos
            importedVideos = snapshot.importedVideos
            failed = snapshot.failed
            undated = snapshot.undated
            notImported = snapshot.notImported
            importedIds = snapshot.importedIds
            loaded = true
            await loadRecent(snapshot.recentIds, generation: generation)
        }
    }

    /// Thumbnails come from the cache the importer filled; nothing is downloaded for the strip.
    private func loadRecent(_ ids: [String], generation: Int) async {
        guard ids != recent.map(\.id) else { return }
        let known = Dictionary(uniqueKeysWithValues: recent.map { ($0.id, $0.image) })
        let env = AppEnvironment.shared
        var thumbs: [RecentThumb] = []
        for id in ids {
            if let image = known[id] {
                thumbs.append(RecentThumb(id: id, image: image))
                continue
            }
            let store = env.store
            guard let item = await Task.detached(operation: { try? store.item(id: id) }).value,
                  let image = try? await env.media.thumbnail(for: item, urgent: false) else { continue }
            thumbs.append(RecentThumb(id: id, image: image))
        }
        guard generation == self.generation else { return }
        recent = thumbs
    }

    private struct Snapshot: Sendable {
        var sources: [SourceRow]
        var photos: Int
        var videos: Int
        var already: Int
        var notMedia: Int
        var waiting: Int
        var importedPhotos: Int
        var importedVideos: Int
        var failed: [String]
        var undated: [String]
        var notImported: [String]
        var recentIds: [String]
        var importedIds: Set<String>
    }

    nonisolated private static func snapshot(cataloguing: Bool, importing: Bool, notMedia: Int) -> Snapshot {
        let store = AppEnvironment.shared.store
        let records = (try? store.importSources()) ?? []
        let items = (try? store.importItems(status: nil)) ?? []
        let counts = (try? store.importCounts()) ?? [:]
        let lists = TakeoutImportLists.results(in: store)
        let finishedIds = (try? store.finishedSourceIds(records.map(\.id))) ?? []
        let sources = records.map { record -> SourceRow in
            let missing = OpenedImport.resolve(record.bookmark) == nil
            let finished = finishedIds.contains(record.id)
            let status: String
            if cataloguing {
                status = "Reading…"
            } else if missing {
                status = "Choose it again"
            } else if finished {
                status = "Done"
            } else if importing {
                status = "Importing"
            } else {
                status = "Ready"
            }
            return SourceRow(id: record.id, name: record.name, status: status, kind: record.kind,
                             bytes: record.size, finished: finished && !cataloguing && !missing)
        }
        return Snapshot(
            sources: sources,
            photos: items.filter { $0.0.kind != .video }.count,
            videos: items.filter { $0.0.kind == .video }.count,
            already: counts[.duplicate] ?? 0,
            notMedia: notMedia,
            waiting: counts[.waitingForDetails] ?? 0,
            importedPhotos: lists.photos,
            importedVideos: lists.videos,
            failed: lists.failed,
            undated: lists.undated,
            notImported: lists.notMedia,
            recentIds: (try? store.recentImportedItemIds(limit: 6)) ?? [],
            importedIds: Set((try? store.recentImportedItemIds(limit: Int.max)) ?? []))
    }
}

#if DEBUG
/// A tiny Takeout folder, used only when the UI test passes `-uitestTakeoutFixture`.
enum TakeoutFixture {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-uitestTakeoutFixture") }

    static func make() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LelvoTakeoutFixture", isDirectory: true)
        let folder = root.appendingPathComponent("Takeout/Google Photos/Photos from 2019", isDirectory: true)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            guard let jpeg = Data(base64Encoded: Self.tinyJPEG) else {
                throw ImportFailure("Lelvo couldn't prepare the sample files. Run the test again.")
            }
            try jpeg.write(to: folder.appendingPathComponent("IMG_0001.jpg"))
            try Data(Self.sidecar.utf8).write(to: folder.appendingPathComponent("IMG_0001.jpg.json"))
            try Data("Not a photo or video.\n".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        } catch let error as ImportFailure {
            throw error
        } catch {
            throw ImportFailure("Lelvo couldn't prepare the sample files. Run the test again.")
        }
        return root
    }

    /// A 1×1 JPEG, the same bytes the Takeout fixture script uses.
    private static let tinyJPEG = "/9j/4AAQSkZJRgABAQAAAQABAAD/2wCEAAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB"
        + "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQH/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAAA//aAAgBAQABPxA="

    private static let sidecar = #"{"title":"IMG_0001.jpg","photoTakenTime":{"timestamp":"1562257320"}}"#
}
#endif

extension GalleryFilter {
    /// The items a Takeout import uploaded. They're cloud-only, and the timeline names cloud-only entries `cloud-<id>`.
    static func imported(_ itemIds: Set<String>) -> GalleryFilter {
        .matching(title: "Imported", ids: Set(itemIds.map { "cloud-\($0)" }))
    }
}

/// What the guide's button does, from where the import stands.
enum TakeoutGuideAction: Equatable {
    /// Open Files. `fresh` clears an import that's completely done, so a new export starts clean.
    case choose(fresh: Bool)
    /// A zip of the same export was finished and more may come: open Files and add it to this import.
    case addNextZip
    /// An import is under way: go back to it.
    case continueImport

    var title: String {
        switch self {
        case .choose: return "Choose files"
        case .addNextZip: return "Add the next zip"
        case .continueImport: return "Continue import"
        }
    }
}

extension TakeoutImporter {
    var guideAction: TakeoutGuideAction {
        switch state {
        case .idle: return .choose(fresh: false)
        case .finished: return allFilesAdded ? .choose(fresh: true) : .addNextZip
        default: return .continueImport
        }
    }
}
