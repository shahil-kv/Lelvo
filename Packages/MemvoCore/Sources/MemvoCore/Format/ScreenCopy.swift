import Foundation
import ImageIO
import UniformTypeIdentifiers

/// When to store a screen copy (role `d`) of a photo. A cloud photo can only be shown once its whole file is here:
/// 22–38 MB RAW photos took 4–7 s to open, while a 2048 px JPEG of a few hundred KB shows in well under a second.
/// Like Google Photos and iCloud Photos, the copy shows first and the original loads when zooming in. Normal photos
/// of a few MB are skipped: they open quickly anyway, and a copy each would double the uploads.
public enum ScreenCopyPolicy {
    /// Long side of the copy, in pixels: sharp on any iPhone screen and a Mac window.
    public static let maxPixel = 2048
    public static let jpegQuality = 0.82
    /// Smaller photos open about as fast as their copy would.
    public static let minimumBytes: Int64 = 3 << 20
    /// A copy is kept only when it's at most this fraction of the original.
    public static let maximumSizeRatio = 0.5
    static let rawExtensions: Set<String> = ["dng", "arw", "cr2", "cr3", "nef", "nrw", "raf", "orf", "rw2", "pef", "srw", "x3f", "3fr", "iiq"]

    /// The file the viewer shows (the edit when there is one) and its size.
    public static func shown(_ item: MediaItem) -> (name: String, size: Int64) {
        if item.hasEdit == true, let size = item.editedSize { return (item.editedFilename ?? item.filename, size) }
        return (item.filename, item.fileSize)
    }

    public static func isRAW(_ filename: String) -> Bool {
        rawExtensions.contains((filename as NSString).pathExtension.lowercased())
    }

    public static func shouldMake(_ item: MediaItem) -> Bool {
        guard item.kind == .photo || item.kind == .livePhoto, item.screenCopySkipped != true, !item.hasScreenCopy else { return false }
        let shown = shown(item)
        return shown.size >= minimumBytes || isRAW(shown.name)
    }

    public static func isWorthKeeping(copyBytes: Int64, originalBytes: Int64) -> Bool {
        originalBytes > 0 && Double(copyBytes) <= Double(originalBytes) * maximumSizeRatio
    }
}

extension MediaItem {
    /// A complete screen copy is in the cloud.
    public var hasScreenCopy: Bool {
        let have = parts("d").count
        return have > 0 && have == (expectedParts?["d"] ?? 1)
    }
}


public enum ScreenCopyError: LocalizedError {
    case unreadable
    public var errorDescription: String? { "This photo can't be made into a screen copy." }
}

/// Makes the screen copy of a photo (role `d`, `ScreenCopyPolicy`): a JPEG at most 2048 px on the long side, turned the
/// way the photo is shown, with its colour profile. ImageIO reads HEIC, JPEG, PNG and RAW alike and only decodes what
/// the smaller size needs, so even a 50 MP RAW stays light on memory.
public enum ScreenCopyEncoder {
    public static func encode(_ source: URL, to output: URL) throws -> (url: URL, width: Int, height: Int) {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ScreenCopyError.unreadable
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: ScreenCopyPolicy.maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { throw ScreenCopyError.unreadable }
        try? FileManager.default.removeItem(at: output)
        guard let dest = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ScreenCopyError.unreadable
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: ScreenCopyPolicy.jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ScreenCopyError.unreadable }
        return (output, image.width, image.height)
    }
}
