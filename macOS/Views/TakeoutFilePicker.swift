import AppKit
import UniformTypeIdentifiers

/// Files or a folder the user already has. The panel returns the originals; nothing is copied into the app.
enum TakeoutFilePicker {
    @MainActor
    static func choose(onPick: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip, .folder]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.prompt = "Choose"
        panel.message = "Choose Takeout zip files, or a folder of them."
        guard panel.runModal() == .OK else { return }
        onPick(panel.urls)
    }
}
