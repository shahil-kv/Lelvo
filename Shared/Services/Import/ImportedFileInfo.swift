import Foundation
import ImageIO
import AVFoundation
import CoreGraphics
import UniformTypeIdentifiers
import LelvoCore

/// Size, capture date, place and a thumbnail read from a file already extracted to disk.
/// ImageIO and AVFoundation run off the main actor. A file the system can't decode comes back with no thumbnail;
/// the importer still uploads the original and supplies a placeholder.
struct ImportedFileInfo: Sendable {
    var width: Int
    var height: Int
    var duration: Double? = nil
    var codec: String? = nil
    /// `0` SDR, `1` HDR, `2` Dolby Vision. Nil when the file has no video track.
    var hdr: Int? = nil
    var takenAt: Date? = nil
    var tzMinutes: Int? = nil
    var latitude: Double? = nil
    var longitude: Double? = nil
    var thumbnailJPEG: Data? = nil

    /// Long side and byte cap of a backup thumbnail (a JPEG of about 320 px, under 200 KB).
    private static let thumbnailMaxPixel: CGFloat = 320
    private static let thumbnailMaxBytes = 200_000

    static func read(_ url: URL, kind: MediaKind) async -> ImportedFileInfo {
        await Task.detached(priority: .utility) {
            switch kind {
            case .video:
                return await readVideo(url)
            case .photo, .livePhoto:
                return readImage(url)
            }
        }.value
    }

    // MARK: - Images

    private static func readImage(_ url: URL) -> ImportedFileInfo {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
            return ImportedFileInfo(width: 0, height: 0)
        }
        let props = dictionary(CGImageSourceCopyPropertiesAtIndex(source, 0, nil)) ?? [:]
        // Phone photos store the sensor's landscape pixels plus a rotation tag. `wh` is the displayed size.
        let orientation = int(props[kCGImagePropertyOrientation]) ?? 1
        var width = int(props[kCGImagePropertyPixelWidth]) ?? 0
        var height = int(props[kCGImagePropertyPixelHeight]) ?? 0
        if orientation >= 5 { swap(&width, &height) }

        let exif = dictionary(props[kCGImagePropertyExifDictionary])
        let taken = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            .flatMap { ExifDate.parse($0, offset: exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String) }
        let gps = dictionary(props[kCGImagePropertyGPSDictionary])
        return ImportedFileInfo(
            width: width, height: height,
            takenAt: taken?.date, tzMinutes: taken?.tzMinutes,
            latitude: gps.flatMap { coordinate($0, value: kCGImagePropertyGPSLatitude, ref: kCGImagePropertyGPSLatitudeRef, negative: "S") },
            longitude: gps.flatMap { coordinate($0, value: kCGImagePropertyGPSLongitude, ref: kCGImagePropertyGPSLongitudeRef, negative: "W") },
            thumbnailJPEG: imageThumbnail(source))
    }

    /// ImageIO's latitude and longitude are positive; the ref says which hemisphere.
    private static func coordinate(_ gps: [CFString: Any], value: CFString, ref: CFString, negative: String) -> Double? {
        guard let raw = double(gps[value]) else { return nil }
        guard let letter = (gps[ref] as? String)?.uppercased() else { return raw }
        return letter == negative ? -abs(raw) : abs(raw)
    }

    private static func imageThumbnail(_ source: CGImageSource) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixel
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return jpeg(image, maxPixel: thumbnailMaxPixel, maxBytes: thumbnailMaxBytes)
    }

    // MARK: - Videos

    private static func readVideo(_ url: URL) async -> ImportedFileInfo {
        let asset = AVURLAsset(url: url)
        let seconds = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) }
        let duration = (seconds?.isFinite == true && (seconds ?? 0) > 0) ? seconds : nil
        let taken = await captureDate(of: asset)
        let info = await VideoInfo.inspect(asset: asset)
        let size = await displaySize(of: asset)
        return ImportedFileInfo(
            width: size.width, height: size.height, duration: duration,
            codec: info?.codec, hdr: info.map(\.hdr),
            takenAt: taken?.date, tzMinutes: taken?.tzMinutes,
            thumbnailJPEG: await videoThumbnail(asset, duration: duration ?? 0))
    }

    private static func displaySize(of asset: AVAsset) async -> (width: Int, height: Int) {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return (0, 0) }
        let size = natural.applying(transform)
        return (Int(abs(size.width).rounded()), Int(abs(size.height).rounded()))
    }

    /// QuickTime keeps the zone on the creation-date string (`2019-07-04T18:22:01+0530`). Prefer that over `dateValue`,
    /// which is only the instant. A stamp with no zone is read as UTC, same as an EXIF date with no offset.
    private static func captureDate(of asset: AVAsset) async -> (date: Date, tzMinutes: Int?)? {
        let common = (try? await asset.load(.commonMetadata)) ?? []
        let all = (try? await asset.load(.metadata)) ?? []
        let groups: [[AVMetadataItem]] = [
            all.filter { $0.identifier == .quickTimeMetadataCreationDate },
            common.filter { $0.commonKey == .commonKeyCreationDate || $0.identifier == .commonIdentifierCreationDate },
            all.filter { $0.identifier == .quickTimeUserDataCreationDate }
        ]
        for item in groups.joined() {
            if let string = try? await item.load(.stringValue), let parsed = parseStamp(string) { return parsed }
            if let date = try? await item.load(.dateValue) {
                let zone = (try? await item.load(.stringValue)).flatMap(offsetMinutes(in:))
                return (date, zone)
            }
        }
        return nil
    }

    private static func parseStamp(_ raw: String) -> (date: Date, tzMinutes: Int?)? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains(" "), let exif = ExifDate.parse(text, offset: nil) { return exif }
        let zone = offsetMinutes(in: text)
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let normalized = colonOffset(text)
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            formatter.formatOptions = options
            if let date = formatter.date(from: normalized) { return (date, zone) }
        }
        guard zone == nil else { return nil }
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            formatter.formatOptions = options
            if let date = formatter.date(from: normalized + "Z") { return (date, nil) }
        }
        return nil
    }

    /// `Z`, `±HH:MM` or `±HHMM` at the end of an ISO-8601 stamp. Nil when the stamp names no zone.
    private static func offsetMinutes(in text: String) -> Int? {
        if text.hasSuffix("Z") { return 0 }
        let tail = text.suffix(12)
        guard let sign = tail.lastIndex(where: { $0 == "+" || $0 == "-" }) else { return nil }
        let body = tail[tail.index(after: sign)...]
        let fields: [Substring]
        if body.contains(":") {
            fields = body.split(separator: ":").filter { !$0.isEmpty }
        } else if body.count == 4 || body.count == 6, body.allSatisfy(\.isNumber) {
            let chars = Array(body)
            fields = [Substring(chars[0...1]), Substring(chars[2...3])]
        } else {
            return nil
        }
        guard fields.count >= 2, fields.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isNumber) }),
              let hours = Int(fields[0]), let mins = Int(fields[1]),
              (0...23).contains(hours), (0...59).contains(mins) else { return nil }
        let total = hours * 60 + mins
        return tail[sign] == "-" ? -total : total
    }

    /// `+0530` is what QuickTime writes; `ISO8601DateFormatter` wants `+05:30`.
    private static func colonOffset(_ text: String) -> String {
        guard let sign = text.lastIndex(where: { $0 == "+" || $0 == "-" }) else { return text }
        let body = text[text.index(after: sign)...]
        guard (body.count == 4 || body.count == 6), body.allSatisfy(\.isNumber) else { return text }
        let hours = body.prefix(2)
        let mins = body.dropFirst(2).prefix(2)
        var rewritten = String(text[..<text.index(after: sign)]) + hours + ":" + mins
        if body.count == 6 { rewritten += ":" + body.suffix(2) }
        return rewritten
    }

    /// A frame about 1 s in, or the first frame when the clip is shorter.
    private static func videoThumbnail(_ asset: AVAsset, duration: Double) async -> Data? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: thumbnailMaxPixel, height: thumbnailMaxPixel)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let at = duration > 1 ? CMTime(seconds: 1, preferredTimescale: 600) : .zero
        if let image = try? await generator.image(at: at).image { return jpeg(image, maxPixel: thumbnailMaxPixel, maxBytes: thumbnailMaxBytes) }
        guard at != .zero, let image = try? await generator.image(at: .zero).image else { return nil }
        return jpeg(image, maxPixel: thumbnailMaxPixel, maxBytes: thumbnailMaxBytes)
    }

    // MARK: - JPEG

    private static func jpeg(_ image: CGImage, maxPixel: CGFloat, maxBytes: Int) -> Data? {
        var current = image
        var side = maxPixel
        while side >= 80 {
            if CGFloat(max(current.width, current.height)) > side {
                current = scaled(image, maxPixel: side) ?? current
            }
            for quality in stride(from: 0.75, through: 0.3, by: -0.15) {
                if let data = encodeJPEG(current, quality: quality), data.count <= maxBytes { return data }
            }
            side *= 0.8
            current = scaled(image, maxPixel: side) ?? current
        }
        return encodeJPEG(current, quality: 0.3)
    }

    private static func scaled(_ image: CGImage, maxPixel: CGFloat) -> CGImage? {
        let ratio = min(1, maxPixel / CGFloat(max(image.width, image.height)))
        let w = max(1, Int((CGFloat(image.width) * ratio).rounded()))
        let h = max(1, Int((CGFloat(image.height) * ratio).rounded()))
        guard w != image.width || h != image.height else { return image }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private static func encodeJPEG(_ image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    // MARK: - Property lists

    private static func dictionary(_ value: Any?) -> [CFString: Any]? {
        if let dict = value as? [CFString: Any] { return dict }
        guard let dict = value as? [String: Any] else { return nil }
        var out: [CFString: Any] = [:]
        for (key, entry) in dict { out[key as CFString] = entry }
        return out
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }
}
