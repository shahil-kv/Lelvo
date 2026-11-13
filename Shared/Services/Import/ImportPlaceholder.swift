import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import LelvoCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// A grey square with a photo or video symbol, drawn once. An encrypted item needs a thumbnail to count as backed
/// up, and some Takeout files (an old codec, a RAW the system doesn't know) have none of their own.
enum ImportPlaceholder {
    private static let lock = NSLock()
    private static var cache: [String: Data] = [:]
    private static let side = 320

    static func jpeg(for kind: MediaKind) -> Data {
        let symbol = kind == .video ? "video" : "photo"
        lock.lock()
        if let cached = cache[symbol] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let data = render(symbol: symbol) ?? greySquare()
        lock.lock()
        cache[symbol] = data
        lock.unlock()
        return data
    }

    private static func render(symbol: String) -> Data? {
        #if os(iOS)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            UIColor(white: 0.78, alpha: 1).setFill()
            UIBezierPath(rect: CGRect(x: 0, y: 0, width: side, height: side)).fill()
            let config = UIImage.SymbolConfiguration(pointSize: 96, weight: .medium)
            let glyph = UIImage(systemName: symbol, withConfiguration: config)?
                .withTintColor(UIColor(white: 0.38, alpha: 1), renderingMode: .alwaysOriginal)
            if let glyph {
                let fitted = glyph.size
                glyph.draw(in: CGRect(x: (CGFloat(side) - fitted.width) / 2, y: (CGFloat(side) - fitted.height) / 2,
                                      width: fitted.width, height: fitted.height))
            }
        }
        return image.jpegData(compressionQuality: 0.85)
        #else
        let canvas = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor(white: 0.78, alpha: 1).setFill()
            rect.fill()
            let config = NSImage.SymbolConfiguration(pointSize: 96, weight: .medium)
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let fitted = glyph.size
                glyph.draw(in: NSRect(x: (CGFloat(side) - fitted.width) / 2, y: (CGFloat(side) - fitted.height) / 2,
                                      width: fitted.width, height: fitted.height))
            }
            return true
        }
        guard let tiff = canvas.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        #endif
    }

    /// Used only when a symbol can't be drawn. Still a real JPEG, so the encrypted upload can finish.
    private static func greySquare() -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return Data() }
        ctx.setFillColor(CGColor(gray: 0.78, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        guard let image = ctx.makeImage() else { return Data() }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return Data() }
        return data as Data
    }
}
