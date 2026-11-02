import Foundation
import LelvoCore
#if os(macOS)
import AppKit
#endif

/// Live state of Keep a second copy, for Settings.
@MainActor
final class SecondCopyActivity: ObservableObject {
    static let shared = SecondCopyActivity()

    enum Phase: Equatable { case off, checking, copying, upToDate, paused, needsSpace, failed }

    @Published var phase: Phase = .off
    /// "Lelvo copy on Backup SSD".
    @Published var folderName: String?
    @Published var files = 0
    @Published var bytes: Int64 = 0
    @Published var left = 0
    @Published var leftBytes: Int64 = 0
    @Published var current: String?
    /// Items copied earlier that are no longer in the library; their files stay in the folder.
    @Published var removedFromLibrary = 0
    /// Why it's paused or what went wrong, in plain words.
    @Published var message: String?
}

/// Keep a second copy (#71): keeps a folder the user chose, on an external drive, a NAS or this Mac, in step with the
/// Telegram library, so their photos also live somewhere they own. It only ever adds files: nothing is deleted from the
/// folder, even after the photo is deleted from the library (non-negotiable 1).
///
/// A pass runs at launch, every few minutes, when a drive is plugged in and when the user asks. Each pass reads the
/// index, compares it with the manifest in the folder (`SecondCopy.plan`) and downloads what's missing, one file at a
/// time through `MediaReader` (decrypted, TDLib's cache evicted after each file). It waits while a backup is running so
/// copying never competes with uploads.
final class SecondCopyService: @unchecked Sendable {
    private unowned let env: AppEnvironment
    private let lock = NSLock()
    private var running: Task<Void, Never>?
    private var runAgain = false
    private var loop: Task<Void, Never>?
    private var mountObserver: NSObjectProtocol?

    /// Between catch-up passes. Each pass is a database read and a size check per file; it downloads only what's new.
    private static let interval: UInt64 = 5 * 60 * 1_000_000_000
    /// Kept free on the drive so the copy never fills it to the last byte.
    private static let spareBytes: Int64 = 500 << 20

    init(environment: AppEnvironment) { self.env = environment }

    var isOn: Bool { Prefs.secondCopyBookmark != nil }

    /// Starts the background passes. Mac only for now: an iPhone's own storage is too small for most libraries.
    func start() {
        #if os(macOS)
        lock.lock()
        defer { lock.unlock() }
        guard loop == nil else { return }
        loop = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                self?.syncNow()
                try? await Task.sleep(nanoseconds: Self.interval)
            }
        }
        mountObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: nil) { [weak self] _ in
            self?.syncNow()
        }
        #endif
    }

    /// The user picked a folder: remember it and start copying.
    func choose(_ folder: URL) throws {
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.isWritableFile(atPath: folder.path) else { throw SecondCopyError.notWritable }
        Prefs.secondCopyBookmark = try folder.bookmarkData(options: [], includingResourceValuesForKeys: [.volumeNameKey], relativeTo: nil)
        Prefs.secondCopyVolume = try? folder.resourceValues(forKeys: [.volumeNameKey]).volumeName
        appLog("Second copy: folder chosen")
        cancelRun()
        syncNow()
    }

    /// Stops keeping the copy. The folder and everything in it stay as they are.
    func turnOff() {
        cancelRun()
        Prefs.secondCopyBookmark = nil
        Prefs.secondCopyVolume = nil
        appLog("Second copy turned off; the folder keeps its files")
        Task { @MainActor in
            let a = SecondCopyActivity.shared
            a.phase = .off; a.folderName = nil; a.files = 0; a.bytes = 0; a.left = 0; a.leftBytes = 0
            a.current = nil; a.removedFromLibrary = 0; a.message = nil
        }
    }

    /// Stops a pass in progress (sign out, reset). Files already copied stay.
    func cancelRun() {
        lock.lock()
        let task = running
        runAgain = false
        lock.unlock()
        task?.cancel()
    }

    /// Runs a pass now, or straight after the one in progress.
    func syncNow() {
        lock.lock()
        defer { lock.unlock() }
        if running != nil { runAgain = true; return }
        running = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            repeat { await self.pass() } while self.takeRunAgain() && !Task.isCancelled
            self.finishRun()
        }
    }

    private func finishRun() {
        lock.lock()
        running = nil
        lock.unlock()
    }

    private func takeRunAgain() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let again = runAgain
        runAgain = false
        return again
    }

    // MARK: - A pass

    private func pass() async {
        guard let bookmark = Prefs.secondCopyBookmark else {
            await publish { $0.phase = .off }
            return
        }
        guard !DemoMode.isActive, env.isConfigured else { return }
        guard let folder = resolve(bookmark) else {
            let drive = Prefs.secondCopyVolume ?? "the drive"
            await publish { $0.phase = .paused; $0.message = "Paused. Connect \(drive) to continue." }
            return
        }
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        let name = Self.displayName(folder)
        // Copy after the backup, not alongside it: uploads keep the connection to themselves.
        if env.engine.isRunning {
            await publish { $0.folderName = name; if $0.phase == .off { $0.phase = .checking } }
            return
        }
        await publish { $0.folderName = name; if $0.phase != .copying { $0.phase = .checking } }

        let fm = FileManager.default
        let manifestURL = folder.appendingPathComponent(SecondCopy.Manifest.fileName)
        var manifest = (try? Data(contentsOf: manifestURL)).flatMap { try? JSONDecoder().decode(SecondCopy.Manifest.self, from: $0) } ?? .init()
        let items = ((try? env.store.items(status: .backedUp)) ?? []).filter(\.isViewableFromCloud)
        func sizeOnDisk(_ path: String) -> Int64? {
            (try? fm.attributesOfItem(atPath: folder.appendingPathComponent(path).path)[.size] as? NSNumber)?.int64Value
        }
        let plan = SecondCopy.plan(items: items, manifest: manifest, calendar: Calendar(identifier: .gregorian), sizeOnDisk: sizeOnDisk)
        for file in plan.toAdopt { manifest.record(file, size: file.size) }
        if !plan.toAdopt.isEmpty { save(manifest, to: manifestURL) }

        var files = plan.upToDate + plan.toAdopt.count
        var bytes = plan.upToDateBytes + plan.toAdopt.reduce(0) { $0 + $1.size }
        var left = plan.toCopy.count
        var leftBytes = plan.bytesToCopy
        let removed = plan.removedFromLibrary
        await publish {
            $0.files = files; $0.bytes = bytes; $0.left = left; $0.leftBytes = leftBytes
            $0.removedFromLibrary = removed; $0.message = nil
            $0.phase = left == 0 ? .upToDate : .copying
        }
        guard left > 0 else { return }
        appLog("Second copy: \(left) files to copy, \(files) already there")

        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var failed = 0
        var lastError: String?
        var unsaved = 0
        var stopped: SecondCopyActivity.Phase?
        var stopMessage: String?
        for file in plan.toCopy {
            if Task.isCancelled || Prefs.secondCopyBookmark == nil || env.engine.isRunning { break }
            guard (try? folder.checkResourceIsReachable()) == true else {
                stopped = .paused
                stopMessage = "Paused. Connect \(Prefs.secondCopyVolume ?? "the drive") to continue."
                break
            }
            if let free = Self.freeSpace(folder), free < file.size + Self.spareBytes {
                stopped = .needsSpace
                stopMessage = "\(name) is almost full. Free up \(Format.bytes(leftBytes + Self.spareBytes - free)) there to copy the rest."
                break
            }
            guard let item = byId[file.itemId] else { continue }
            let label = (file.path as NSString).lastPathComponent
            await publish { $0.current = label }
            let dest = folder.appendingPathComponent(file.path)
            // Written next to its final place, then moved: a pulled cable leaves a hidden partial file, never a broken
            // photo with the right name.
            let partial = dest.deletingLastPathComponent().appendingPathComponent(".lelvo-partial-\(UUID().uuidString)")
            do {
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await env.reader.download(item, role: file.role, to: partial, evict: true)
                let written = (try fm.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.int64Value ?? 0
                if file.size > 0, written != file.size {
                    AppLog.shared.warn("Second copy: a file came out at \(written) bytes, the index says \(file.size)")
                }
                // Only our own earlier copy can be at `dest` (the plan never picks a path holding someone else's file).
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.moveItem(at: partial, to: dest)
                if let date = file.date {
                    try? fm.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: dest.path)
                }
                manifest.record(file, size: written)
                unsaved += 1
                if unsaved >= 20 { save(manifest, to: manifestURL); unsaved = 0 }
                files += 1; bytes += written; left -= 1; leftBytes = max(0, leftBytes - file.size)
                let (f, b, l, lb) = (files, bytes, left, leftBytes)
                await publish { $0.files = f; $0.bytes = b; $0.left = l; $0.leftBytes = lb }
            } catch {
                try? fm.removeItem(at: partial)
                if error is CancellationError || Task.isCancelled { break }
                failed += 1
                lastError = error.localizedDescription
                AppLog.shared.warn("Second copy: a file couldn't be copied: \(error.localizedDescription)")
            }
        }
        save(manifest, to: manifestURL)
        appLog("Second copy pass finished: \(files) files in the folder, \(left) left, \(failed) failed")

        let (l, lb, msg) = (left, leftBytes, lastError)
        let (stop, stopMsg) = (stopped, stopMessage)
        let failures = failed
        await publish {
            $0.current = nil
            $0.left = l; $0.leftBytes = lb
            if let stop {
                $0.phase = stop; $0.message = stopMsg
            } else if l == 0 {
                $0.phase = .upToDate; $0.message = nil
            } else if failures > 0 {
                $0.phase = .failed
                $0.message = msg.map { "\(failures) couldn't be copied (\($0)). Lelvo tries again in a few minutes." }
            } else {
                // Stopped for a backup or a new pass; the next pass carries on.
                $0.phase = .copying
            }
        }
    }

    // MARK: - Helpers

    private func resolve(_ bookmark: Data) -> URL? {
        var stale = false
        // `.withoutMounting`: an unplugged drive means paused, not a Finder prompt to connect a server.
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &stale),
              (try? url.checkResourceIsReachable()) == true else { return nil }
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: [.volumeNameKey], relativeTo: nil) {
            Prefs.secondCopyBookmark = fresh
        }
        return url
    }

    private func save(_ manifest: SecondCopy.Manifest, to url: URL) {
        do {
            try JSONEncoder().encode(manifest).write(to: url, options: .atomic)
        } catch {
            AppLog.shared.warn("Second copy: couldn't save the list of copied files: \(error.localizedDescription)")
        }
    }

    private static func displayName(_ folder: URL) -> String {
        let volume = (try? folder.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? nil
        guard let volume, volume != folder.lastPathComponent else { return folder.lastPathComponent }
        return "\(folder.lastPathComponent) on \(volume)"
    }

    /// External drives often don't report the "important usage" figure; fall back to plain free space.
    private static func freeSpace(_ folder: URL) -> Int64? {
        guard let v = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]) else { return nil }
        if let important = v.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return v.volumeAvailableCapacity.map(Int64.init)
    }

    private func publish(_ change: @escaping @MainActor (SecondCopyActivity) -> Void) async {
        await MainActor.run { change(SecondCopyActivity.shared) }
    }
}

enum SecondCopyError: LocalizedError {
    case notWritable

    var errorDescription: String? {
        switch self {
        case .notWritable: "Lelvo can't write to that folder. Pick a folder you can save files in."
        }
    }
}
