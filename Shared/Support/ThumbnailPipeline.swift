import Foundation
import Photos
#if os(iOS)
import UIKit
#else
import AppKit
#endif
import MemvoCore

/// Grid thumbnails the way Photos does it: an in-memory cache so tiles that scroll back in show instantly,
/// loading ahead of the scroll (Photos' own caching manager for local photos, Telegram thumbnails for cloud
/// items), and nothing decoded on the main thread.
final class ThumbnailPipeline: @unchecked Sendable {
    static let shared = ThumbnailPipeline()

    /// Best image so far per entry, with its pixel size.
    private final class Box {
        let image: PlatformImage
        let pixels: Int
        init(image: PlatformImage, pixels: Int) { self.image = image; self.pixels = pixels }
    }

    private let memory = NSCache<NSString, Box>()
    /// The same manager the grid requests go through, so caching ahead actually serves those requests.
    private var caching: PHCachingImageManager { AppEnvironment.shared.photos.gridImages }
    private let lock = NSLock()
    private var prefetching: [String: Task<Void, Never>] = [:]

    private init() {
        memory.countLimit = 3000
        #if os(macOS)
        memory.totalCostLimit = 400 * 1024 * 1024
        #else
        memory.totalCostLimit = 150 * 1024 * 1024
        #endif
    }

    /// Grid sizes in 128-pixel steps, so zooming the grid doesn't reload every frame.
    static func bucket(_ pixels: CGFloat) -> Int { (Int(pixels) / 128 + 1) * 128 }

    /// The cached image, if any (any size: a smaller one is shown until the sharp one arrives).
    func cached(_ entry: GalleryEntry) -> (image: PlatformImage, pixels: Int)? {
        memory.object(forKey: entry.id as NSString).map { ($0.image, $0.pixels) }
    }

    private func store(_ image: PlatformImage, pixels: Int, for id: String, shared: Bool = false) {
        if let existing = memory.object(forKey: id as NSString), existing.pixels > pixels { return }
        // Shared images (demo data) are counted once, not per tile.
        let cost = shared ? 1 : Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        memory.setObject(Box(image: image, pixels: pixels), forKey: id as NSString, cost: cost)
    }

    /// Low-res first, then sharp (each delivered on the main actor). Ends when the sharp image is in.
    func images(for entry: GalleryEntry, pixels: Int) -> AsyncStream<PlatformImage> {
        AsyncStream { cont in
            if let box = memory.object(forKey: entry.id as NSString), box.pixels >= pixels {
                cont.yield(box.image)
                cont.finish()
                return
            }
            let env = AppEnvironment.shared
            let task = Task.detached(priority: .userInitiated) { [self] in
                if let asset = entry.asset {
                    for await raw in env.photos.thumbnails(for: asset, pixels: CGFloat(pixels)) {
                        if Task.isCancelled { break }
                        let img = await Self.decoded(raw)
                        // The first delivery is Photos' quick low-res version; only the sharp one counts as full size.
                        let shortSide = min(img.size.width, img.size.height) * img.scale
                        store(img, pixels: shortSide >= CGFloat(pixels) * 0.6 ? pixels : pixels / 4, for: entry.id)
                        cont.yield(img)
                    }
                } else if let item = entry.item {
                    var img = env.media.cachedThumbnail(for: item)
                    if img == nil { img = try? await env.media.thumbnail(for: item) }
                    if let raw = img, !Task.isCancelled {
                        let img = await Self.decoded(raw)
                        // Cloud thumbnails come from Telegram at ~320 px; that is the sharpest there is.
                        store(img, pixels: Int.max, for: entry.id)
                        cont.yield(img)
                    }
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// Decodes the bitmap here, in the background, so showing it on screen costs the main thread nothing.
    private static func decoded(_ image: PlatformImage) async -> PlatformImage {
        #if os(iOS)
        return await image.byPreparingForDisplay() ?? image
        #else
        return image
        #endif
    }

    // MARK: - Loading ahead

    /// Starts loading thumbnails for items about to scroll into view.
    func prefetch(_ entries: [GalleryEntry], pixels: Int) {
        let assets = entries.compactMap(\.asset)
        if !assets.isEmpty {
            caching.startCachingImages(for: assets, targetSize: CGSize(width: pixels, height: pixels), contentMode: .aspectFill, options: Self.cachingOptions)
        }
        let env = AppEnvironment.shared
        for entry in entries where entry.asset == nil {
            guard let item = entry.item, memory.object(forKey: entry.id as NSString) == nil, env.media.cachedThumbnail(for: item) == nil else { continue }
            lock.lock()
            let running = prefetching[entry.id] != nil
            if !running {
                prefetching[entry.id] = Task.detached(priority: .utility) { [self] in
                    if let img = try? await env.media.thumbnail(for: item, urgent: false) { store(img, pixels: Int.max, for: entry.id) }
                    _ = lock.withLock { prefetching.removeValue(forKey: entry.id) }
                }
            }
            lock.unlock()
        }
    }

    /// Items that scrolled far away again: stop loading them.
    func cancelPrefetch(_ entries: [GalleryEntry], pixels: Int) {
        let assets = entries.compactMap(\.asset)
        if !assets.isEmpty {
            caching.stopCachingImages(for: assets, targetSize: CGSize(width: pixels, height: pixels), contentMode: .aspectFill, options: Self.cachingOptions)
        }
        lock.lock()
        for entry in entries { prefetching.removeValue(forKey: entry.id)?.cancel() }
        lock.unlock()
    }

    #if DEBUG
    /// Benchmarks: in-memory thumbnails for the demo library (no Photos or Telegram involved).
    func seedDemoThumbnails(ids: [String]) {
        let palette: [PlatformImage] = (0..<48).map { i in Self.demoImage(i) }
        for (i, id) in ids.enumerated() { store(palette[i % palette.count], pixels: Int.max, for: id, shared: true) }
    }

    private static func demoImage(_ i: Int) -> PlatformImage {
        let size = CGSize(width: 384, height: 384)
        let hue = CGFloat(i) / 48
        #if os(iOS)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let colors = [UIColor(hue: hue, saturation: 0.7, brightness: 0.9, alpha: 1).cgColor,
                          UIColor(hue: hue + 0.1, saturation: 0.8, brightness: 0.4, alpha: 1).cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: nil)!
            ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        }
        #else
        return NSImage(size: size, flipped: false) { rect in
            NSColor(hue: hue, saturation: 0.7, brightness: 0.8, alpha: 1).setFill()
            rect.fill()
            return true
        }
        #endif
    }
    #endif

    func clearMemory() {
        memory.removeAllObjects()
        caching.stopCachingImagesForAllAssets()
    }

    private static let cachingOptions: PHImageRequestOptions = {
        let o = PHImageRequestOptions()
        o.deliveryMode = .opportunistic
        o.resizeMode = .fast
        o.isNetworkAccessAllowed = true
        return o
    }()
}
