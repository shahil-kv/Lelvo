#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: lets a script on this Mac snapshot the main window and drive a few UI actions,
/// without Screen Recording or Accessibility permissions.
///   snapshot: post "com.shahil-kv.lelvo.debug.snapshot" with object = output PNG path
///   action:   post "com.shahil-kv.lelvo.debug.action" with object = "go:library|go:backup|open:<n>|key:left|key:right|key:escape"
enum DebugHooks {
    @MainActor static func install() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: .init("com.shahil-kv.lelvo.debug.snapshot"), object: nil, queue: .main) { note in
            guard let path = note.object as? String else { return }
            MainActor.assumeIsolated { snapshot(to: URL(fileURLWithPath: path)) }
        }
        center.addObserver(forName: .init("com.shahil-kv.lelvo.debug.action"), object: nil, queue: .main) { note in
            guard let action = note.object as? String else { return }
            MainActor.assumeIsolated { perform(action) }
        }
    }

    @MainActor private static func findGrid(_ v: NSView) -> NSScrollView? {
        if let s = v as? NSScrollView, s.documentView is NSCollectionView { return s }
        for sub in v.subviews { if let found = findGrid(sub) { return found } }
        return nil
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
        case "export":
            NotificationCenter.default.post(name: .debugExportIndex, object: Int(arg) ?? 0)
        case "reswitch":
            // Switches to the current (unencrypted) library again, to time the whole switch.
            Task {
                let env = AppEnvironment.shared
                guard let id = env.library.chatId else { return }
                do { try await env.switchLibrary(to: id, passphrase: nil) } catch { AppLog.shared.error("reswitch: \(error.localizedDescription)") }
            }
        case "exportkeys":
            // Writes this Mac's Telegram app keys as Config/Secrets.xcconfig, so builds carry them.
            guard let id = KeychainStore.string(for: .tdApiId), let hash = KeychainStore.string(for: .tdApiHash) else {
                appLog("exportkeys: no keys in the Keychain")
                return
            }
            try? "TD_API_ID = \(id)\nTD_API_HASH = \(hash)\n".write(toFile: arg, atomically: true, encoding: .utf8)
            appLog("exportkeys: written")
        case "push":
            NotificationCenter.default.post(name: .debugPush, object: arg)
        case "move":
            let xy = arg.split(separator: ",").compactMap { Double($0) }
            guard xy.count == 2, let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 }),
                  let content = window.contentView else { return }
            let p = NSPoint(x: xy[0], y: content.bounds.height - xy[1])
            if let e = NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                window.sendEvent(e)
            }
        case "click", "rclick":
            // "click:x,y" in window points from the top-left of the content.
            let xy = arg.split(separator: ",").compactMap { Double($0) }
            guard xy.count == 2, let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 }),
                  let content = window.contentView else { return }
            let p = NSPoint(x: xy[0], y: content.bounds.height - xy[1])
            let (down, up): (NSEvent.EventType, NSEvent.EventType) = verb == "click" ? (.leftMouseDown, .leftMouseUp) : (.rightMouseDown, .rightMouseUp)
            for type in [down, up] {
                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(e)
                }
            }
        case "scrolltest":
            // Scrolls the grid top to bottom in 4 s at display rate and logs how late frames were (main-thread hitches).
            guard let root = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 })?.contentView,
                  let scroll = findGrid(root) else { return }
            let clip = scroll.contentView
            let total = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
            let start = CACurrentMediaTime()
            var last = start
            var gaps: [Double] = []
            Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { timer in
                MainActor.assumeIsolated {
                    let now = CACurrentMediaTime()
                    gaps.append(now - last)
                    last = now
                    let t = min(1, (now - start) / 4)
                    clip.scroll(to: NSPoint(x: 0, y: total * t))
                    scroll.reflectScrolledClipView(clip)
                    if t >= 1 {
                        timer.invalidate()
                        let sorted = gaps.sorted()
                        let p95 = sorted[Int(Double(sorted.count) * 0.95)]
                        appLog(String(format: "Debug scrolltest: %d ticks, avg %.1f ms, p95 %.1f ms, max %.1f ms, >33ms: %d",
                                      gaps.count, gaps.reduce(0, +) / Double(gaps.count) * 1000, p95 * 1000, (sorted.last ?? 0) * 1000,
                                      gaps.filter { $0 > 0.033 }.count))
                    }
                }
            }
        case "dump":
            func walk(_ v: NSView, _ depth: Int) {
                if let sv = v as? NSScrollView {
                    appLog("Debug: scroll \(type(of: sv.documentView as Any)) frame \(sv.frame) clip \(sv.contentView.bounds) insets \(sv.contentInsets.top),\(sv.contentView.contentInsets.top) doc \(sv.documentView?.frame ?? .zero)")
                }
                for s in v.subviews { walk(s, depth + 1) }
            }
            if let root = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 })?.contentView { walk(root, 0) }
        case "activate":
            NSApp.activate()
        default: break
        }
    }
}

extension Notification.Name {
    static let debugOpenIndex = Notification.Name("Lelvo.debugOpenIndex")
    static let debugPush = Notification.Name("Lelvo.debugPush")
    static let debugExportIndex = Notification.Name("Lelvo.debugExportIndex")
}
#endif
