import SwiftUI
import AppKit
import Photos
import MemvoCore

/// Progress and result messages shown as a floating pill at the bottom of the window.
@MainActor
final class ToastCenter: ObservableObject {
    struct Toast: Equatable {
        enum Style { case progress, success, failure, info }
        var style: Style
        var title: String
        var detail: String?
        var progress: Double?
    }

    @Published private(set) var current: Toast?
    private var hideTask: Task<Void, Never>?

    func progress(_ title: String, detail: String? = nil, fraction: Double? = nil) {
        hideTask?.cancel()
        current = Toast(style: .progress, title: title, detail: detail, progress: fraction)
    }

    func show(_ style: Toast.Style, _ title: String, detail: String? = nil, seconds: Double = 3.5) {
        hideTask?.cancel()
        current = Toast(style: style, title: title, detail: detail)
        hideTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            current = nil
        }
    }

    func dismiss() {
        hideTask?.cancel()
        current = nil
    }
}

struct ToastView: View {
    let toast: ToastCenter.Toast

    var body: some View {
        HStack(spacing: 12) {
            switch toast.style {
            case .progress:
                if let p = toast.progress { ProgressView(value: p).progressViewStyle(.circular).controlSize(.small) }
                else { ProgressView().controlSize(.small) }
            case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
            case .failure: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title3)
            case .info: Image(systemName: "info.circle.fill").foregroundStyle(.tint).font(.title3)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(toast.title).font(.callout.weight(.semibold))
                if let detail = toast.detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .overlay(Capsule().strokeBorder(.separator.opacity(0.5)))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        .frame(maxWidth: 520)
    }
}

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

    /// Prepares originals (downloading cloud items) with progress in the toast; returns the files that worked.
    static func prepareFiles(_ entries: [GalleryEntry], toast: ToastCenter, verb: String) async -> [URL] {
        var urls: [URL] = []
        var failures = 0
        for (i, entry) in entries.enumerated() {
            toast.progress("\(verb) \(i + 1) of \(entries.count)…", fraction: Double(i) / Double(max(entries.count, 1)))
            do { urls.append(try await GalleryActions.shareableFile(for: entry)) } catch { failures += 1 }
        }
        if failures > 0 {
            toast.show(.failure, "\(failures) item\(failures == 1 ? "" : "s") couldn't be downloaded", detail: "Check your connection and try again.")
        } else {
            toast.dismiss()
        }
        return urls
    }

    static func share(_ entries: [GalleryEntry], toast: ToastCenter) async {
        let urls = await prepareFiles(entries, toast: toast, verb: "Preparing")
        share(urls)
    }

    /// Exports originals (with their real names and dates) into a folder the user picks.
    static func export(_ entries: [GalleryEntry], toast: ToastCenter) async {
        guard !entries.isEmpty, let folder = chooseFolder(message: "Choose where to export \(entries.count) item\(entries.count == 1 ? "" : "s").") else { return }
        let files = await prepareFiles(entries, toast: toast, verb: "Exporting")
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
        var saved = 0
        var lastError: String?
        for (i, item) in items.enumerated() {
            toast.progress("Saving to Photos \(i + 1) of \(items.count)…", fraction: Double(i) / Double(items.count))
            do { try await GalleryActions.saveToPhotos(item); saved += 1 } catch { lastError = error.localizedDescription }
        }
        if let lastError {
            toast.show(.failure, "Saved \(saved), \(items.count - saved) failed", detail: lastError)
        } else {
            toast.show(.success, "Saved \(saved) item\(saved == 1 ? "" : "s") to Photos")
        }
    }

    static func backUp(_ entries: [GalleryEntry], toast: ToastCenter) async {
        let ids = entries.filter { [.phoneOnly, .failed, .waiting].contains($0.badge) }.compactMap { $0.asset?.localIdentifier }
        guard !ids.isEmpty else { return }
        let n = await Task.detached { AppEnvironment.shared.engine.enqueue(localIdentifiers: ids) }.value
        ContinuedBackup.start()
        toast.show(.info, "Backing up \(n) item\(n == 1 ? "" : "s")", detail: "Progress is in the sidebar and on the Backup page.")
    }

    static func deleteFromCloud(_ entries: [GalleryEntry], toast: ToastCenter) async {
        let items = entries.compactMap(\.item).filter { $0.status == .backedUp }
        guard !items.isEmpty else { return }
        toast.progress("Deleting \(items.count) from your backup…")
        do {
            try await GalleryActions.deleteFromCloud(items)
            toast.show(.success, "Moved \(items.count) to Recently Deleted", detail: "They're removed from your Telegram library after 30 days.")
        } catch {
            toast.show(.failure, "Couldn't delete", detail: error.localizedDescription)
        }
    }

    static func deleteFromMac(_ entries: [GalleryEntry], toast: ToastCenter) async {
        let ids = entries.compactMap { $0.asset?.localIdentifier }
        guard !ids.isEmpty else { return }
        do {
            try await AppEnvironment.shared.photos.deleteAssets(ids)
            toast.show(.success, "Moved to Recently Deleted", detail: "Empty Recently Deleted in Photos to free the space.")
        } catch {
            // The user cancelled macOS's confirmation.
        }
    }
}

/// Which actions apply to a set of entries (menus, toolbar and the selection bar share this).
struct EntryActions {
    let entries: [GalleryEntry]

    var downloadable: [GalleryEntry] { entries.filter { $0.isCloudOnly && $0.item?.isViewableFromCloud == true } }
    var notBackedUp: [GalleryEntry] { entries.filter { $0.asset != nil && [.phoneOnly, .failed, .waiting].contains($0.badge) } }
    var inCloud: [GalleryEntry] { entries.filter { $0.item?.status == .backedUp } }
    var onMac: [GalleryEntry] { entries.filter { $0.asset != nil } }
    var unsafeOnMac: Int { onMac.filter { $0.badge != .backedUp }.count }
}
