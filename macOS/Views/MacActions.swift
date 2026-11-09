import SwiftUI
import AppKit
import Photos
import LelvoCore

/// Sharing, exporting and the other file-based actions for one or more gallery entries.
@MainActor
enum MacActions {
    /// Shows the system share menu (AirDrop, Messages, Mail…) at the mouse pointer.
    static func share(_ urls: [URL]) {
        guard !urls.isEmpty, let window = NSApp.keyWindow, let view = window.contentView else { return }
        let picker = NSSharingServicePicker(items: urls)
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        picker.show(relativeTo: NSRect(x: point.x, y: point.y, width: 1, height: 1), of: view, preferredEdge: .minY)
    }

    /// Lets the user pick a folder (Desktop by default).
    static func chooseFolder(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        panel.message = message
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Prepares originals (downloading cloud items) with progress in the toast; returns the files that worked, or
    /// nothing if the user stopped it (run inside `ToastCenter.runStoppable`).
    static func prepareFiles(_ entries: [GalleryEntry], toast: ToastCenter, verb: String, originals: Bool = false) async -> [URL] {
        var urls: [URL] = []
        var failures = 0
        let count = max(entries.count, 1)
        for (i, entry) in entries.enumerated() {
            if Task.isCancelled { return [] }
            toast.progress("\(verb) \(i + 1) of \(entries.count)…", fraction: Double(i) / Double(count))
            do {
                urls.append(try await GalleryActions.shareableFile(for: entry, original: originals) { p in
                    Task { @MainActor in toast.update(fraction: (Double(i) + p) / Double(count)) }
                })
            } catch {
                if Task.isCancelled { return [] }
                failures += 1
            }
        }
        if failures > 0 {
            toast.show(.failure, "\(failures) item\(failures == 1 ? "" : "s") couldn't be downloaded", detail: "Check your connection and try again.")
        } else {
            toast.dismiss()
        }
        return urls
    }

    static func share(_ entries: [GalleryEntry], toast: ToastCenter) async {
        await toast.runStoppable {
            let urls = await prepareFiles(entries, toast: toast, verb: "Preparing")
            if !Task.isCancelled { share(urls) }
        }
    }

    /// Exports originals (with their real names and dates) into a folder the user picks.
    /// `originals`: the untouched originals instead of what Photos shows, like "Export Unmodified Original" in Photos.
    static func export(_ entries: [GalleryEntry], toast: ToastCenter, originals: Bool = false) async {
        guard !entries.isEmpty, let folder = chooseFolder(message: "Choose where to export \(entries.count) item\(entries.count == 1 ? "" : "s").") else { return }
        var files: [URL] = []
        await toast.runStoppable { files = await prepareFiles(entries, toast: toast, verb: "Exporting", originals: originals) }
        let fm = FileManager.default
        var moved = 0
        for file in files {
            var dest = folder.appendingPathComponent(file.lastPathComponent)
            var n = 1
            while fm.fileExists(atPath: dest.path) {
                n += 1
                dest = folder.appendingPathComponent("\(file.deletingPathExtension().lastPathComponent) \(n).\(file.pathExtension)")
            }
            if (try? fm.moveItem(at: file, to: dest)) != nil { moved += 1 }
            try? fm.removeItem(at: file.deletingLastPathComponent())
        }
        if moved > 0 {
            toast.show(.success, "Exported \(moved) item\(moved == 1 ? "" : "s")", detail: folder.path)
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }

    static func saveToPhotos(_ entries: [GalleryEntry], toast: ToastCenter) async {
        let items = entries.filter(\.isCloudOnly).compactMap(\.item).filter(\.isViewableFromCloud)
        guard !items.isEmpty else { return }
        await toast.runStoppable {
            var saved = 0
            var lastError: String?
            let count = Double(items.count)
            for (i, item) in items.enumerated() {
                if Task.isCancelled { break }
                toast.progress("Saving to Photos \(i + 1) of \(items.count)…", fraction: Double(i) / count)
                do {
                    try await GalleryActions.saveToPhotos(item) { p in
                        Task { @MainActor in toast.update(fraction: (Double(i) + p) / count) }
                    }
                    saved += 1
                } catch {
                    if Task.isCancelled { break }
                    lastError = error.localizedDescription
                }
            }
            if Task.isCancelled {
                if saved > 0 { toast.show(.info, "Stopped. \(saved) saved to Photos") }
            } else if let lastError {
                toast.show(.failure, "Saved \(saved), \(items.count - saved) failed", detail: lastError)
            } else {
                toast.show(.success, "Saved \(saved) item\(saved == 1 ? "" : "s") to Photos")
            }
        }
    }

    static func backUp(_ entries: [GalleryEntry], toast: ToastCenter) async {
        let ids = entries.filter { [.phoneOnly, .failed, .waiting].contains($0.badge) }.compactMap { $0.asset?.localIdentifier }
        guard !ids.isEmpty else { return }
        let n = await Task.detached { AppEnvironment.shared.engine.enqueue(localIdentifiers: ids) }.value
        ContinuedBackup.start()
        toast.show(.info, "Backing up \(n) item\(n == 1 ? "" : "s")", detail: "Progress is in the sidebar and on the Backup page.")
    }

    static func addToAlbum(_ entries: [GalleryEntry], albumId: String, title: String, toast: ToastCenter) async {
        guard !entries.isEmpty else { return }
        toast.progress("Adding \(entries.count) to “\(title)”…")
        do {
            let result = try await GalleryActions.addToAlbum(entries, albumId: albumId, title: title)
            if result.failed > 0 {
                toast.show(.failure, "Added \(result.added), \(result.failed) still backing up",
                           detail: "Add them once they're in your Telegram library.")
            } else {
                toast.show(.success, "Added \(result.added) to “\(title)”",
                           detail: "Items in your Telegram library join the album in Photos when you save them.")
            }
        } catch {
            toast.show(.failure, "Nothing was added", detail: error.localizedDescription)
        }
    }

    static func setFavorite(_ entries: [GalleryEntry], _ favorite: Bool, toast: ToastCenter) async {
        guard !entries.isEmpty else { return }
        do {
            try await GalleryActions.setFavorite(entries, favorite)
            toast.show(.success, favorite ? "Added to Favorites" : "Removed from Favorites")
        } catch {
            toast.show(.failure, favorite ? "Couldn't add to Favorites" : "Couldn't remove from Favorites", detail: error.localizedDescription)
        }
    }

    static func deleteEverywhere(_ entries: [GalleryEntry], toast: ToastCenter) async {
        guard !entries.isEmpty else { return }
        do {
            let result = try await GalleryActions.deleteEverywhere(entries)
            toast.show(.success, "Deleted \(entries.count) item\(entries.count == 1 ? "" : "s")",
                       detail: result.cloud > 0 ? "You can get them back from Recently Deleted for 30 days." : nil)
        } catch let error as NSError where error.domain == PHPhotosErrorDomain && error.code == PHPhotosError.userCancelled.rawValue {
            // Cancelled in macOS's own confirmation: nothing was deleted anywhere.
        } catch {
            toast.show(.failure, "Couldn't delete everything", detail: "\(error.localizedDescription) Check what's left, then try again.", seconds: 5)
        }
    }

    static func deleteFromMac(_ entries: [GalleryEntry], toast: ToastCenter) async {
        let ids = entries.compactMap { $0.asset?.localIdentifier }
        guard !ids.isEmpty else { return }
        do {
            try await AppEnvironment.shared.photos.deleteAssets(ids)
            toast.show(.success, "Moved to Recently Deleted", detail: "Empty Recently Deleted in Photos to free the space.")
        } catch let error as NSError where error.domain == PHPhotosErrorDomain && error.code == PHPhotosError.userCancelled.rawValue {
            // Cancelled in macOS's own confirmation: nothing happened.
        } catch {
            toast.show(.failure, "Nothing was deleted", detail: "Photos couldn't delete them. Try again from the Photos app.", seconds: 5)
        }
    }
}

/// Which actions apply to a set of entries (menus, toolbar and the selection bar share this).
struct EntryActions {
    let entries: [GalleryEntry]
    // Worked out once: with 100,000 selected, filtering again for every button froze the window on Select All.
    let downloadable: [GalleryEntry]
    let notBackedUp: [GalleryEntry]
    let inCloud: [GalleryEntry]
    let onMac: [GalleryEntry]
    let unsafeOnMac: Int

    init(entries: [GalleryEntry]) {
        self.entries = entries
        var downloadable: [GalleryEntry] = [], notBackedUp: [GalleryEntry] = []
        var inCloud: [GalleryEntry] = [], onMac: [GalleryEntry] = []
        var unsafeOnMac = 0
        for entry in entries {
            if entry.isCloudOnly, entry.item?.isViewableFromCloud == true { downloadable.append(entry) }
            if entry.item?.status == .backedUp { inCloud.append(entry) }
            guard entry.asset != nil else { continue }
            onMac.append(entry)
            if [.phoneOnly, .failed, .waiting].contains(entry.badge) { notBackedUp.append(entry) }
            if entry.badge != .backedUp { unsafeOnMac += 1 }
        }
        self.downloadable = downloadable
        self.notBackedUp = notBackedUp
        self.inCloud = inCloud
        self.onMac = onMac
        self.unsafeOnMac = unsafeOnMac
    }
}
