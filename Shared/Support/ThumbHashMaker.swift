import CoreGraphics
import Foundation
import ImageIO
import LelvoCore

/// Makes the Base64 ThumbHash a caption carries (`th`) from the upload's thumbnail JPEG: shrunk to 100 px, then the maths
/// in `LelvoCore.ThumbHash`. A thumbnail that can't be read gives nil, and the caption then simply has no `th`.
enum ThumbHashMaker {
    static func hash(fromJPEG data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: ThumbHash.maxSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let w = image.width, h = image.height
        guard w >= 1, h >= 1, w <= ThumbHash.maxSide, h <= ThumbHash.maxSide else { return nil }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            // A photo thumbnail is opaque, so premultiplied and straight alpha are the same bytes.
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn, let hash = ThumbHash.encode(width: w, height: h, rgba: rgba) else { return nil }
        return Data(hash).base64EncodedString()
    }
}
