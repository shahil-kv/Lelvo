import Foundation
import CoreGraphics
#if os(iOS)
import UIKit
#else
import AppKit
#endif
import LelvoCore

/// Blurred stand-in pictures for cloud tiles whose thumbnail has not arrived yet. A hash is decoded only when a
/// visible tile asks for it, off the main thread, and the 32 px results (a few KB each) live in a bounded cache.
final class ThumbHashImages: @unchecked Sendable {
    static let shared = ThumbHashImages()

    /// `image` is nil for a malformed hash, so it is not decoded again for every tile that shows it.
    private final class Box {
        let image: PlatformImage?
        init(_ image: PlatformImage?) { self.image = image }
    }

    private let cache = NSCache<NSString, Box>()

    private init() {
        cache.countLimit = 3000
    }

    /// The placeholder if it is already decoded. A dictionary-style lookup: cheap enough for cell configuration.
    func cached(_ hash: String) -> PlatformImage? {
        cache.object(forKey: hash as NSString)?.image
    }

    /// True when this hash is already known, good or bad, so no decode is needed.
    func isResolved(_ hash: String) -> Bool {
        cache.object(forKey: hash as NSString) != nil
    }

    /// Decodes off the main thread. Nil for a malformed hash.
    func image(for hash: String) async -> PlatformImage? {
        if let box = cache.object(forKey: hash as NSString) { return box.image }
        let image = await Task.detached(priority: .utility) { Self.make(hash) }.value
        cache.setObject(Box(image), forKey: hash as NSString, cost: image == nil ? 1 : 32 * 32 * 4)
        return image
    }

    func clearMemory() {
        cache.removeAllObjects()
    }

    private static func make(_ hash: String) -> PlatformImage? {
        guard let data = Data(base64Encoded: hash), !data.isEmpty,
              let decoded = ThumbHash.decode([UInt8](data)),
              decoded.width > 0, decoded.height > 0,
              decoded.rgba.count == decoded.width * decoded.height * 4 else { return nil }
        // ThumbHash RGBA is straight alpha; Core Graphics wants it premultiplied.
        var pixels = decoded.rgba
        var i = 0
        while i < pixels.count {
            let a = UInt32(pixels[i + 3])
            if a != 255 {
                pixels[i] = UInt8((UInt32(pixels[i]) * a + 127) / 255)
                pixels[i + 1] = UInt8((UInt32(pixels[i + 1]) * a + 127) / 255)
                pixels[i + 2] = UInt8((UInt32(pixels[i + 2]) * a + 127) / 255)
            }
            i += 4
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cg = CGImage(
                width: decoded.width, height: decoded.height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: decoded.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        #if os(iOS)
        return UIImage(cgImage: cg)
        #else
        return NSImage(cgImage: cg, size: NSSize(width: decoded.width, height: decoded.height))
        #endif
    }
}

extension GalleryEntry {
    /// The hash to draw while the thumbnail loads: cloud-only items that carry one. Nil for phone items.
    var placeholderHash: String? {
        guard isCloudOnly, let hash = item?.thumbHash, !hash.isEmpty else { return nil }
        return hash
    }
}
