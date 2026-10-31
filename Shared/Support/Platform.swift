import SwiftUI
import ImageIO
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
import IOKit.ps
typealias PlatformImage = NSImage
#endif

/// The device this copy of Lelvo runs on, for user-facing text ("on this iPhone" / "on this Mac").
enum Device {
    #if os(macOS)
    static let name = "Mac"
    static let symbol = "macbook"
    #else
    static let name = "iPhone"
    static let symbol = "iphone"
    #endif

    /// "iPhone", "iPad" or "Mac", as the issue templates' App dropdown names them.
    @MainActor static var kind: String {
        #if os(macOS)
        "Mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }

    /// The hardware model identifier ("iPhone17,1", "Mac15,3"), for bug reports.
    static var model: String {
        #if os(macOS)
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return String(cString: bytes)
        #else
        // The simulator reports the Mac's CPU ("arm64") as its machine; the simulated model is in the environment.
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        #endif
    }

    /// "iOS 26.1", "iPadOS 26.1" or "macOS 26.0.1".
    @MainActor static var osVersion: String {
        #if os(macOS)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
        #else
        return "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        #endif
    }

    /// Whether the device is on external power (Only while charging).
    static var isCharging: Bool {
        #if os(macOS)
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return true }
        return type == kIOPSACPowerValue
        #else
        UIDevice.current.isBatteryMonitoringEnabled = true
        let state = UIDevice.current.batteryState
        return state == .charging || state == .full
        #endif
    }
}

/// Opening URLs and system settings without UIApplication/NSWorkspace at every call site.
enum PlatformActions {
    @MainActor static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    @MainActor static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    /// The system page where the user grants photo access.
    @MainActor static func openPhotoSettings() {
        #if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") { NSWorkspace.shared.open(url) }
        #else
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        #endif
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

extension Color {
    /// Placeholder behind thumbnails that haven't loaded yet.
    static var tileBackground: Color {
        #if os(macOS)
        Color(nsColor: .quaternaryLabelColor)
        #else
        Color(.secondarySystemBackground)
        #endif
    }
}

/// Pixel size of encoded image data, without decoding it.
enum ImageDimensions {
    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              var w = props[kCGImagePropertyPixelWidth] as? Int, var h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        if let o = props[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&w, &h) }
        return (w, h)
    }
}

#if os(macOS)
extension NSImage {
    /// Pixel-sized image, so `size` is in pixels like a scale-1 UIImage.
    convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    var scale: CGFloat { 1 }

    var cgImageValue: CGImage? {
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let cg = cgImageValue else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: compressionQuality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    func scaledToFit(maxPixel: CGFloat) -> NSImage {
        guard let cg = cgImageValue else { return self }
        let ratio = min(1, maxPixel / CGFloat(max(cg.width, cg.height)))
        let w = max(1, Int((CGFloat(cg.width) * ratio).rounded())), h = max(1, Int((CGFloat(cg.height) * ratio).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return self }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return self }
        return NSImage(cgImage: scaled)
    }

    /// Images from `CGImageSourceCreateThumbnailAtIndex` with `ShouldCacheImmediately` are already decoded.
    func preparingForDisplay() -> NSImage? { self }
}
#endif

/// Feedback for taps and results. Macs have no haptic engine for this, so these do nothing there.
enum Haptics {
    #if os(macOS)
    static func success() {}
    static func error() {}
    static func tap() {}
    static func selection() {}
    #else
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
    #endif
}

// MARK: - iOS-only modifiers, no-ops on macOS

#if os(macOS)
typealias UITextContentType = NSTextContentType
#endif

enum PlatformKeyboard { case `default`, numberPad }

extension View {
    @ViewBuilder func inlineNavigationTitle() -> some View {
        #if os(macOS)
        self
        #else
        navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder func platformKeyboard(_ keyboard: PlatformKeyboard) -> some View {
        #if os(macOS)
        self
        #else
        keyboardType(keyboard == .numberPad ? .numberPad : .default)
        #endif
    }

    @ViewBuilder func platformSearchable(text: Binding<String>, prompt: String) -> some View {
        #if os(macOS)
        searchable(text: text, prompt: prompt)
        #else
        searchable(text: text, placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)
        #endif
    }

    /// iOS-style tinted buttons instead of the Mac's bezeled push buttons (screens designed for iPhone).
    @ViewBuilder func macBorderlessButtons() -> some View {
        #if os(macOS)
        buttonStyle(.borderless)
        #else
        self
        #endif
    }

    /// System Settings-style grouped sections on the Mac (iOS lists are already grouped).
    @ViewBuilder func platformGroupedForm() -> some View {
        #if os(macOS)
        formStyle(.grouped)
        #else
        self
        #endif
    }

    @ViewBuilder func noAutocapitalization() -> some View {
        #if os(macOS)
        self
        #else
        textInputAutocapitalization(.never)
        #endif
    }
}
