#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: lets a script on this Mac snapshot the main window and drive a few UI actions,
/// without Screen Recording or Accessibility permissions.
///   snapshot: post "com.shahil-kv.cloudgallery.debug.snapshot" with object = output PNG path
///   action:   post "com.shahil-kv.cloudgallery.debug.action" with object = "go:library|go:backup|open:<n>|key:left|key:right|key:escape"
enum DebugHooks {
    @MainActor static func install() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: .init("com.shahil-kv.cloudgallery.debug.snapshot"), object: nil, queue: .main) { note in
            guard let path = note.object as? String else { return }
            MainActor.assumeIsolated { snapshot(to: URL(fileURLWithPath: path)) }
        }
        center.addObserver(forName: .init("com.shahil-kv.cloudgallery.debug.action"), object: nil, queue: .main) { note in
            guard let action = note.object as? String else { return }
            MainActor.assumeIsolated { perform(action) }
        }
    }

    @MainActor private static func snapshot(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    @MainActor private static func perform(_ action: String) {
        let parts = action.split(separator: ":", maxSplits: 1).map(String.init)
        guard let verb = parts.first else { return }
        let arg = parts.count > 1 ? parts[1] : ""
        switch verb {
        case "go":
            let items: [String: SidebarItem] = ["library": .library, "backup": .backup, "videos": .videos,
                                                "cloud": .cloudOnly, "notbackedup": .notBackedUp, "favorites": .favorites]
            if let item = items[arg] { MacNavigation.shared.selection = item }
        case "open":
            NotificationCenter.default.post(name: .debugOpenIndex, object: Int(arg) ?? 0)
        case "key":
            let codes: [String: (UInt16, String)] = ["left": (123, "\u{F702}"), "right": (124, "\u{F703}"), "escape": (53, "\u{1B}"), "space": (49, " ")]
            guard let (code, chars) = codes[arg], let window = NSApp.keyWindow ?? NSApp.windows.first,
                  let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                              context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
            else { return }
            window.sendEvent(down)
        case "push":
            NotificationCenter.default.post(name: .debugPush, object: arg)
        case "activate":
            NSApp.activate()
        default: break
        }
    }
}

extension Notification.Name {
    static let debugOpenIndex = Notification.Name("CloudGallery.debugOpenIndex")
    static let debugPush = Notification.Name("CloudGallery.debugPush")
}
#endif
