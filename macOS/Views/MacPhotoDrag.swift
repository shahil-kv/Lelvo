import AppKit
import Photos
import UniformTypeIdentifiers

/// Dragging photos out of Lelvo (the grid and the viewer) into Finder, Mail, Messages, ChatGPT, a browser or Slack.
///
/// Most apps only take a real file, the way Finder drags one; a file promise works in Finder and Mail but browsers and
/// chat apps ignore it. So the file is prepared as soon as the mouse goes down on a photo, and a drag that starts once it
/// is ready carries the file itself. A video or a large cloud original isn't prepared on every click; it goes as a
/// promise, which writes it where the drop lands.
@MainActor
final class PhotoDragSource: NSObject, NSDraggingSource, NSFilePromiseProviderDelegate {
    static let shared = PhotoDragSource()

    /// Cloud originals up to this size are fetched on mouse down; bigger ones only when dropped.
    private static let eagerCloudLimit: Int64 = 40 << 20
    /// How long a drag waits for files still being prepared before it falls back to promises.
    private static let readyWait: TimeInterval = 0.6

    private var pressed: [String: PreparedDragFile] = [:]
    /// The last drag's files: the app they were dropped on may still be reading them.
    private var dropped: [PreparedDragFile] = []

    private nonisolated let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// Mouse down on a photo: starts preparing what a drag from here would carry.
    func pressed(_ entries: [GalleryEntry]) {
        discardPressed()
        // A click while selecting presses the whole selection; only the first few are worth preparing on every click.
        for entry in entries.prefix(Self.eagerItems) where Self.preparesEarly(entry) {
            let file = PreparedDragFile()
            file.start(entry)
            pressed[entry.id] = file
        }
    }

    /// Mouse up without a drag: the prepared files aren't needed.
    func released() { discardPressed() }

    func beginDrag(_ entries: [GalleryEntry], from view: NSView, event: NSEvent, image: NSImage, frame: NSRect) {
        let group = Array(entries.prefix(Self.maxItems))
        guard !group.isEmpty else { return }
        let deadline = Date().addingTimeInterval(Self.readyWait)
        // The previous drag's files go, except a promise still being written where it was dropped (a slow cloud
        // download); that one goes at the next drag after it finishes, or at the next launch.
        dropped = dropped.filter { !$0.discardIfFinished() }
        var offset: CGFloat = 0
        let items: [NSDraggingItem] = group.map { entry in
            let writer: NSPasteboardWriting
            let prepared = pressed.removeValue(forKey: entry.id)
            if let prepared, let url = prepared.wait(seconds: max(0, deadline.timeIntervalSinceNow)) {
                dropped.append(prepared)
                writer = url as NSURL
            } else {
                let name = Self.filename(for: entry)
                let type = UTType(filenameExtension: (name as NSString).pathExtension) ?? (entry.isVideo ? .movie : .image)
                let provider = PhotoDragProvider(fileType: type.identifier, delegate: self)
                provider.userInfo = entry
                if let prepared { provider.adopt(prepared) } else { provider.file.start(entry) }
                dropped.append(provider.file)
                writer = provider
            }
            let item = NSDraggingItem(pasteboardWriter: writer)
            item.setDraggingFrame(frame.offsetBy(dx: offset, dy: -offset), contents: image)
            offset += 4
            return item
        }
        discardPressed()
        view.beginDraggingSession(with: items, event: event, source: self)
    }

    private func discardPressed() {
        for file in pressed.values { file.discard() }
        pressed = [:]
    }

    private static let maxItems = 50
    private static let eagerItems = 8

    private static func preparesEarly(_ entry: GalleryEntry) -> Bool {
        if entry.isVideo { return false }
        if entry.asset != nil { return true }
        return (entry.item?.fileSize ?? .max) <= eagerCloudLimit
    }

    // MARK: NSDraggingSource

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    // MARK: NSFilePromiseProviderDelegate

    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        guard let entry = provider.userInfo as? GalleryEntry else { return "Photo" }
        return Self.filename(for: entry)
    }

    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        guard let entry = provider.userInfo as? GalleryEntry else { completionHandler(nil); return }
        let prepared = (provider as? PhotoDragProvider)?.file
        Task {
            do {
                let early = try await prepared?.result()
                let file: URL
                if let early { file = early } else { file = try await GalleryActions.shareableFile(for: entry) }
                try? FileManager.default.removeItem(at: url)
                // Copied, not moved: the same file may also have been handed out as a file URL.
                try FileManager.default.copyItem(at: file, to: url)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    nonisolated func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue {
        promiseQueue
    }

    nonisolated static func filename(for entry: GalleryEntry) -> String {
        if let asset = entry.asset {
            let resources = PHAssetResource.assetResources(for: asset)
            return (resources.first { $0.type == .fullSizePhoto || $0.type == .fullSizeVideo } ?? resources.first)?.originalFilename ?? "Photo"
        }
        return entry.item.map(CloudMediaService.displayedFilename) ?? "Photo"
    }
}

/// A dragged photo that wasn't ready when the drag began. Finder takes the file promise; apps that only take real
/// files ask for a file URL instead, which waits for the file being prepared.
final class PhotoDragProvider: NSFilePromiseProvider {
    private(set) var file = PreparedDragFile()

    func adopt(_ prepared: PreparedDragFile) { file = prepared }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.fileURL]
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        type == .fileURL ? .promised : super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        guard type == .fileURL else { return super.pasteboardPropertyList(forType: type) }
        // AppKit asks on the main thread at the drop. The file is prepared off it (no main-actor work), so waiting
        // can't deadlock; a cloud original that takes longer than a minute drops nothing rather than hanging.
        return file.wait(seconds: 60)?.absoluteString
    }
}

/// The file behind one dragged photo, prepared once and shared by the promise and the file URL.
final class PreparedDragFile: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var task: Task<URL, Error>?
    private var url: URL?
    private var discarded = false
    private var finished = false

    func start(_ entry: GalleryEntry) {
        lock.withLock {
            guard task == nil else { return }
            task = Task.detached { [weak self] in
                defer {
                    self?.lock.withLock { self?.finished = true }
                    self?.done.signal()
                }
                let file = try await GalleryActions.shareableFile(for: entry)
                let keep = self?.lock.withLock { () -> Bool in
                    guard let self, !self.discarded else { return false }
                    self.url = file
                    return true
                } ?? false
                // Released before it was ready: nobody will use it.
                if !keep { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
                return file
            }
        }
    }

    func result() async throws -> URL? {
        try await lock.withLock { task }?.value
    }

    func wait(seconds: Double) -> URL? {
        if let url = lock.withLock({ url }) { return url }
        guard seconds > 0, done.wait(timeout: .now() + seconds) == .success else { return nil }
        done.signal()
        return lock.withLock { url }
    }

    /// Discards it unless it's still being made; returns whether it was discarded.
    func discardIfFinished() -> Bool {
        let running = lock.withLock { task != nil && url == nil && !finished }
        if running { return false }
        discard()
        return true
    }

    /// Cancels it and removes its file (each prepared file sits in a folder of its own).
    func discard() {
        let file: URL? = lock.withLock {
            discarded = true
            task?.cancel()
            defer { url = nil }
            return url
        }
        if let file { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    }
}
