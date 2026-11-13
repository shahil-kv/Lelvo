import SwiftUI
import LelvoCore

/// The zips and folders the user has added, and the import itself. Deleting a finished zip waits for its own
/// confirmation; this screen only adds files, starts, pauses, and says when every file is here.
struct TakeoutImportView: View {
    @ObservedObject private var importer: TakeoutImporter
    @ObservedObject private var activity = BackupActivity.shared
    @StateObject private var model = TakeoutImportModel()
    @Environment(\.dynamicTypeSize) private var dynamicType
    @State private var space: (needed: Int64, free: Int64)?
    @State private var addError: String?
    @State private var fixtureLoading = false

    init() {
        importer = AppEnvironment.shared.importer
    }

    var body: some View {
        Form {
            filesSection
            if model.loaded { summarySection }
            if let space, hasFiles { spaceSection(space) }
            if let message = importer.message { messageSection(message) }
            if isCataloguing { readingSection }
            if showsStart || isImporting || isCataloguing { actionSection }
            if !importLanes.isEmpty { lanesSection }
            if showsAllFiles { allFilesSection }
            if case .finished = importer.state {
                Section {
                    Text("These photos and videos are in your Telegram library.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .platformGroupedForm()
        .navigationTitle("Import")
        .onAppear {
            captureSpace()
            reload()
            Task { await loadFixtureIfNeeded() }
        }
        .onChange(of: importer.state) { _, _ in
            captureSpace()
            reload()
        }
        .onChange(of: importer.notMedia) { _, _ in reload() }
        .alert("Couldn't add these files", isPresented: showAddError) {
            Button("OK", role: .cancel) { addError = nil }
        } message: {
            Text(addError ?? "")
        }
    }

    private var showAddError: Binding<Bool> {
        Binding(get: { addError != nil }, set: { if !$0 { addError = nil } })
    }

    private var hasFiles: Bool { !model.sources.isEmpty || model.photos + model.videos > 0 }

    private var isCataloguing: Bool {
        if case .cataloguing = importer.state { return true }
        return false
    }

    private var isImporting: Bool {
        if case .importing = importer.state { return true }
        return false
    }

    private var showsStart: Bool {
        switch importer.state {
        case .ready, .paused: return true
        default: return false
        }
    }

    private var canStart: Bool {
        if case .ready(let needed, let free) = importer.state, needed > free { return false }
        return showsStart
    }

    private var showsAllFiles: Bool {
        switch importer.state {
        case .idle, .finished, .cataloguing: return false
        default: return hasFiles
        }
    }

    private var importLanes: [(key: String, lane: BackupActivity.LaneProgress)] {
        activity.lanes
            .filter { $0.key.hasPrefix("import-") }
            .sorted { $0.key < $1.key }
            .map { (key: $0.key, lane: $0.value) }
    }

    private var filesSection: some View {
        Section {
            if model.sources.isEmpty && model.loaded && !isCataloguing {
                Text("Choose the zip files from Google Takeout, or a folder of them.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.sources) { source in
                valueRow(source.name, source.status)
            }
            Button("Choose files", action: choose)
                .disabled(isImporting)
        }
    }

    private var summarySection: some View {
        Section {
            valueRow("Photos", model.photos.formatted())
            valueRow("Videos", model.videos.formatted())
            valueRow("Already in your library", model.already.formatted())
            valueRow("Not photos or videos", model.notMedia.formatted())
            valueRow("Waiting for details", model.waiting.formatted())
        }
    }

    private func spaceSection(_ space: (needed: Int64, free: Int64)) -> some View {
        Section {
            valueRow("Space needed", Format.bytes(space.needed))
            valueRow("Free on this \(Device.name)", Format.bytes(space.free))
        } footer: {
            if space.needed > space.free {
                Text("There isn't enough space. Free up \(Format.bytes(space.needed - space.free)) or move the zip to a USB drive.")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func messageSection(_ message: String) -> some View {
        Section {
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var readingSection: some View {
        Section {
            ProgressView("Reading the files…")
        }
    }

    private var actionSection: some View {
        Section {
            if isImporting || isCataloguing {
                Button("Pause") { importer.pause() }
            } else if showsStart {
                Button("Start import") { importer.start() }
                    .disabled(!canStart)
            }
        } footer: {
            Text("Keep Lelvo open while it imports.")
        }
    }

    private var lanesSection: some View {
        Section("Importing") {
            ForEach(importLanes, id: \.key) { item in
                laneRow(item.key, item.lane)
            }
        }
    }

    private var allFilesSection: some View {
        Section {
            Button("That's all my files") {
                Task { await importer.allFilesAdded() }
            }
            .disabled(isCataloguing)
        }
    }

    /// The same lane row the backup screen uses, for this import's uploads.
    private func laneRow(_ key: String, _ lane: BackupActivity.LaneProgress) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "arrow.up.circle").foregroundStyle(.tint).accessibilityHidden(true)
                Text(lane.name)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if lane.total > 0 {
                    Text("\(Format.bytes(lane.sent)) of \(Format.bytes(lane.total))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .layoutPriority(1)
                } else {
                    Text("Preparing…").font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.footnote)
            if lane.total > 0 {
                ProgressView(value: Double(lane.sent), total: Double(lane.total))
                if let left = activity.secondsLeft[key], left >= 20 {
                    Text(Format.timeLeft(left)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(lane.total > 0
            ? "\(lane.name), \(Format.bytes(lane.sent)) of \(Format.bytes(lane.total))"
            : "\(lane.name), preparing")
    }

    /// Side by side when it fits; stacked at the largest text sizes so the value isn't cut off.
    private func valueRow(_ title: String, _ value: String) -> some View {
        let sideBySide = HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .layoutPriority(1)
        }
        let stacked = VStack(alignment: .leading, spacing: 2) {
            Text(title).fixedSize(horizontal: false, vertical: true)
            Text(value).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        return Group {
            if dynamicType.isAccessibilitySize { stacked } else { sideBySide }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(value)")
    }

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
            let kept = urls.map { (url: $0, accessed: $0.startAccessingSecurityScopedResource()) }
            Task {
                defer {
                    for item in kept where item.accessed { item.url.stopAccessingSecurityScopedResource() }
                }
                await add(kept.map(\.url))
            }
        }
    }

    private func add(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        do {
            try await importer.add(urls: urls)
        } catch {
            addError = error.localizedDescription
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

/// Names and counts for the import screen. The index is read off the main actor.
@MainActor
private final class TakeoutImportModel: ObservableObject {
    struct SourceRow: Identifiable, Equatable, Sendable {
        var id: String
        var name: String
        var status: String
    }

    @Published private(set) var sources: [SourceRow] = []
    @Published private(set) var photos = 0
    @Published private(set) var videos = 0
    @Published private(set) var already = 0
    @Published private(set) var notMedia = 0
    @Published private(set) var waiting = 0
    @Published private(set) var loaded = false

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
            loaded = true
        }
    }

    private struct Snapshot: Sendable {
        var sources: [SourceRow]
        var photos: Int
        var videos: Int
        var already: Int
        var notMedia: Int
        var waiting: Int
    }

    nonisolated private static func snapshot(cataloguing: Bool, importing: Bool, notMedia: Int) -> Snapshot {
        let store = AppEnvironment.shared.store
        let records = (try? store.importSources()) ?? []
        let items = (try? store.importItems(status: nil)) ?? []
        let counts = (try? store.importCounts()) ?? [:]
        let sources = records.map { record -> SourceRow in
            let missing = OpenedImport.resolve(record.bookmark) == nil
            let finished = (try? store.isSourceFinished(id: record.id)) == true
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
            return SourceRow(id: record.id, name: record.name, status: status)
        }
        return Snapshot(
            sources: sources,
            photos: items.filter { $0.0.kind != .video }.count,
            videos: items.filter { $0.0.kind == .video }.count,
            already: counts[.duplicate] ?? 0,
            notMedia: notMedia,
            waiting: counts[.waitingForDetails] ?? 0)
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
