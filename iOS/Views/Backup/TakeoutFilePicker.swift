import UIKit
import UniformTypeIdentifiers

/// Files or a folder the user already has. `asCopy` stays false: a 2 GB zip, often on a USB drive, must not be
/// copied onto the phone before it can be read.
enum TakeoutFilePicker {
    @MainActor
    static func choose(onPick: @escaping ([URL]) -> Void) {
        guard let presenter = presenter else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.zip, .folder], asCopy: false)
        picker.allowsMultipleSelection = true
        let delegate = Delegate(onPick: onPick)
        picker.delegate = delegate
        // The picker would otherwise release the delegate as soon as it is shown.
        objc_setAssociatedObject(picker, &retainKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        presenter.present(picker, animated: true)
    }

    private static var presenter: UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        guard let root = window?.rootViewController else { return nil }
        var top = root
        while let next = top.presentedViewController { top = next }
        return top
    }

    private final class Delegate: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }
    }
}

private var retainKey: UInt8 = 0
