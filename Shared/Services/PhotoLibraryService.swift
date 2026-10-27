import Foundation
import Photos
import AVFoundation
import CoreLocation
#if os(iOS)
import UIKit
#endif
import UniformTypeIdentifiers
import MemvoCore

struct AlbumInfo: Identifiable, Hashable {
    let id: String
    let title: String
    let count: Int
}

/// The original bytes of one asset, exported to disk.
struct ExportedAsset {
    let kind: MediaKind
    let primaryURL: URL
    let primaryFilename: String
    let primaryUTI: String?
    let pairedVideoURL: URL?
    let pairedVideoFilename: String?
    /// The rendered edit (crop, filter, trim…) when the item was edited in Photos.
    var editedURL: URL? = nil
    var editedFilename: String? = nil
    /// The rest of what Photos keeps for this item (edit recipe, RAW of a RAW + JPEG pair, edited Live Photo video).
    var extras: [ExportedExtra] = []

    func cleanup() {
        try? FileManager.default.removeItem(at: primaryURL)
        if let pairedVideoURL { try? FileManager.default.removeItem(at: pairedVideoURL) }
        if let editedURL { try? FileManager.default.removeItem(at: editedURL) }
        for e in extras { try? FileManager.default.removeItem(at: e.url) }
    }
}

/// One more file of an asset, stored under its own caption role (docs/CLOUD_FORMAT.md §2).
struct ExportedExtra {
    /// `ad`, `ad2`, `ra` or `epv`.
    let role: CaptionMeta.Role
    let url: URL
    let filename: String
}

/// On a Mac where the Photos library isn't set up (or is still being opened), every PhotoKit call waits about
/// 30 s for the photos daemon. The library is probed once, off the main thread; until it answers the app works
/// with cloud items only, and if it never answers properly PhotoKit isn't touched again this session.
/// On iPhone the library is always there, so it counts as available straight away.
enum PhotoAvailability {
    enum State { case unknown, probing, available, unavailable }
    static let didChange = Notification.Name("Memvo.photoAvailabilityChanged")
    private static let lock = NSLock()
    #if os(macOS)
    private nonisolated(unsafe) static var state: State = .unknown
    #else
    private nonisolated(unsafe) static var state: State = .available
    #endif

    static var isAvailable: Bool { lock.withLock { state == .available } }

    /// Starts the probe if it hasn't run (call at launch and when the app becomes active).
    static func probeIfNeeded() {
        let start: Bool = lock.withLock {
            guard state == .unknown else { return false }
            state = .probing
            return true
        }
        guard start else { return }
        Task.detached(priority: .userInitiated) {
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard status == .authorized || status == .limited else {
                lock.withLock { state = .unknown }
                return
            }
            let began = Date()
            let options = PHFetchOptions()
            options.fetchLimit = 1
            let found = PHAsset.fetchAssets(with: options).count
            let seconds = Date().timeIntervalSince(began)
            // A real library answers in milliseconds; a long wait with nothing found means there is no usable library.
            let usable = found > 0 || seconds < 5
            lock.withLock { state = usable ? .available : .unavailable }
            appLog(String(format: "Photos library %@ (probe %.1f s)", usable ? "available" : "not set up on this device", seconds))
            await MainActor.run { NotificationCenter.default.post(name: didChange, object: nil) }
        }
    }

    /// After permission is granted (state goes back to unknown, then probes).
    static func reset() {
        lock.withLock { if state != .available { state = .unknown } }
        probeIfNeeded()
    }
}

enum StreamingCopyError: LocalizedError {
    case unsupported
    var errorDescription: String? { "This video can't be converted to a fast version. It still plays in original quality." }
}

enum PhotoLibraryError: LocalizedError {
    case noOriginalResource
    case assetMissing
    case notAuthorized

    var errorDescription: String? {
        switch self {
        case .noOriginalResource: return "This item has no original file to back up."
        case .assetMissing: return "The photo is no longer in your library."
        case .notAuthorized: return "Memvo doesn't have access to your photo library."
        }
    }
}

final class PhotoLibraryService: @unchecked Sendable {
    let gridImages: PHCachingImageManager = {
        let m = PHCachingImageManager()
        m.allowsCachingHighQualityImages = false
        return m
    }()

    /// Grid thumbnails like Photos: a quick low-res image first, then the sharp one. The request is
    /// cancelled as soon as the cell scrolls away, so fast scrolling doesn't queue up hundreds of loads.
    func thumbnails(for asset: PHAsset, pixels: CGFloat) -> AsyncStream<PlatformImage> {
        let manager = gridImages
        return AsyncStream { cont in
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            let id = manager.requestImage(for: asset, targetSize: CGSize(width: pixels, height: pixels),
                                          contentMode: .aspectFill, options: options) { image, info in
                if let image { cont.yield(image) }
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !degraded || info?[PHImageCancelledKey] != nil || info?[PHImageErrorKey] != nil { cont.finish() }
            }
            cont.onTermination = { _ in manager.cancelImageRequest(id) }
        }
    }

    static var authorizationStatus: PHAuthorizationStatus { PHPhotoLibrary.authorizationStatus(for: .readWrite) }

    /// Permission granted and the library actually answers (see `PhotoAvailability`).
    static var hasAccess: Bool {
        let s = authorizationStatus
        return (s == .authorized || s == .limited) && PhotoAvailability.isAvailable
    }

    static func requestAuthorization() async -> PHAuthorizationStatus {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        PhotoAvailability.reset()
        return status
    }

    // MARK: - Fetching

    /// Every photo and video, newest first (used by the gallery).
    /// `includeHidden`: PhotoKit leaves hidden photos out unless asked; only the backup (with Include hidden photos on)
    /// asks. The timeline never shows them.
    func fetchAllAssets(includeHidden: Bool = false) -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                        PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        options.includeHiddenAssets = includeHidden
        return PHAsset.fetchAssets(with: options)
    }

    func asset(localIdentifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
    }

    /// Assets by local identifier, fetched in one go (missing ones are left out).
    func assets(localIdentifiers ids: [String]) -> [String: PHAsset] {
        guard !ids.isEmpty else { return [:] }
        var found: [String: PHAsset] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { a, _, _ in found[a.localIdentifier] = a }
        return found
    }

    func existingIdentifiers(_ ids: [String]) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        var found = Set<String>()
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { a, _, _ in found.insert(a.localIdentifier) }
        return found
    }

    func userAlbums() -> [AlbumInfo] {
        var result: [AlbumInfo] = []
        for type in [PHAssetCollectionType.album, .smartAlbum] {
            let collections = PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil)
            collections.enumerateObjects { c, _, _ in
                let count = PHAsset.fetchAssets(in: c, options: nil).count
                guard count > 0, c.assetCollectionSubtype != .smartAlbumAllHidden,
                      c.assetCollectionSubtype != .smartAlbumRecentlyAdded else { return }
                result.append(AlbumInfo(id: c.localIdentifier, title: c.localizedTitle ?? "Album", count: count))
            }
        }
        return result.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Assets that match the backup selection (media type, screenshots, date range, albums), newest first.
    func backupCandidates() -> [PHAsset] {
        let filter = Prefs.mediaFilter
        let since = Prefs.dateFrom
        let includeScreenshots = Prefs.includeScreenshots
        let mode = Prefs.albumMode
        let albumIds = Prefs.albumIds

        func albumMembers(_ ids: Set<String>) -> Set<String> {
            var members = Set<String>()
            let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: Array(ids), options: nil)
            collections.enumerateObjects { c, _, _ in
                PHAsset.fetchAssets(in: c, options: nil).enumerateObjects { a, _, _ in members.insert(a.localIdentifier) }
            }
            return members
        }

        let included: Set<String>? = (mode == .include) ? albumMembers(albumIds) : nil
        let excluded: Set<String> = (mode == .exclude) ? albumMembers(albumIds) : []

        var out: [PHAsset] = []
        fetchAllAssets(includeHidden: Prefs.includeHidden).enumerateObjects { a, _, _ in
            if a.mediaType == .video && filter == .photos { return }
            if a.mediaType == .image && filter == .videos { return }
            if let since, (a.creationDate ?? .distantPast) < since { return }
            if !includeScreenshots && a.mediaSubtypes.contains(.photoScreenshot) { return }
            if let included, !included.contains(a.localIdentifier) { return }
            if excluded.contains(a.localIdentifier) { return }
            out.append(a)
        }
        return out
    }

    /// Names of the user albums containing `asset` (stored in the caption so albums survive restore).
    func albumNames(for asset: PHAsset) -> [String]? {
        var names: [String] = []
        PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil).enumerateObjects { c, _, _ in
            if let t = c.localizedTitle { names.append(t) }
        }
        return names.isEmpty ? nil : names
    }

    // MARK: - Export

    static func kind(of asset: PHAsset) -> MediaKind {
        if asset.mediaType == .video { return .video }
        if asset.mediaSubtypes.contains(.photoLive) { return .livePhoto }
        return .photo
    }

    /// Picks the unedited original resource(s).
    func originalResources(for asset: PHAsset) -> (primary: PHAssetResource, paired: PHAssetResource?)? {
        let resources = PHAssetResource.assetResources(for: asset)
        func first(_ types: [PHAssetResourceType]) -> PHAssetResource? {
            for t in types { if let r = resources.first(where: { $0.type == t }) { return r } }
            return nil
        }
        switch Self.kind(of: asset) {
        case .video:
            guard let v = first([.video, .fullSizeVideo]) else { return nil }
            return (v, nil)
        case .livePhoto:
            guard let p = first([.photo, .fullSizePhoto]) else { return nil }
            return (p, first([.pairedVideo, .fullSizePairedVideo]))
        case .photo:
            guard let p = first([.photo, .fullSizePhoto, .alternatePhoto]) else { return nil }
            return (p, nil)
        }
    }

    /// Exports original bytes (downloading from iCloud Photos if needed) into `directory`.
    func exportOriginal(of asset: PHAsset, into directory: URL) async throws -> ExportedAsset {
        guard let res = originalResources(for: asset) else { throw PhotoLibraryError.noOriginalResource }
        let base = UUID().uuidString
        var primaryURL = directory.appendingPathComponent("\(base)-\(res.primary.originalFilename.sanitizedFilename)")
        var primaryFilename = res.primary.originalFilename
        var primaryUTI = res.primary.uniformTypeIdentifier
        do {
            try await write(res.primary, to: primaryURL)
        } catch let error as NSError where error.domain == PHPhotosErrorDomain && error.code == PHPhotosError.requestNotSupportedForAsset.rawValue
                    && Self.kind(of: asset) != .video {
            // Some edited photos refuse raw resource export (3306); take the rendered image instead, like the share sheet.
            let (data, uti) = try await renderedImageData(of: asset)
            let ext = uti.flatMap { UTType($0)?.preferredFilenameExtension } ?? "jpg"
            primaryFilename = ((res.primary.originalFilename as NSString).deletingPathExtension as NSString).appendingPathExtension(ext) ?? "\(base).\(ext)"
            primaryUTI = uti ?? UTType.jpeg.identifier
            primaryURL = directory.appendingPathComponent("\(base)-\(primaryFilename.sanitizedFilename)")
            try data.write(to: primaryURL)
            appLog("Exported the rendered image of \(res.primary.originalFilename) (raw export not supported)")
        }
        var pairedURL: URL?
        if let paired = res.paired {
            let url = directory.appendingPathComponent("\(base)-\(paired.originalFilename.sanitizedFilename)")
            do {
                try await write(paired, to: url)
                pairedURL = url
            } catch {
                try? FileManager.default.removeItem(at: primaryURL)
                throw error
            }
        }
        let kind: MediaKind = (Self.kind(of: asset) == .livePhoto && pairedURL == nil) ? .photo : Self.kind(of: asset)
        var exported = ExportedAsset(kind: kind, primaryURL: primaryURL, primaryFilename: primaryFilename,
                                     primaryUTI: primaryUTI, pairedVideoURL: pairedURL,
                                     pairedVideoFilename: res.paired?.originalFilename)
        // Edited in Photos: keep the rendered edit too, so a restore doesn't lose crops, filters or trims.
        if let edit = editedResource(for: asset), edit !== res.primary {
            let url = directory.appendingPathComponent("\(base)-edit-\(edit.originalFilename.sanitizedFilename)")
            do {
                try await write(edit, to: url)
                exported.editedURL = url
                exported.editedFilename = edit.originalFilename
            } catch {
                AppLog.shared.warn("Couldn't export the edited version of \(primaryFilename): \(error.localizedDescription)")
            }
        }
        do {
            exported.extras = try await exportExtras(of: asset, into: directory, edit: exported.editedURL != nil)
        } catch {
            exported.cleanup()
            throw error
        }
        return exported
    }

    /// Everything else Photos keeps for `asset` that a restore needs: the RAW of a RAW + JPEG pair (`ra`), and for an
    /// edited asset its adjustment data (`ad`, `ad2`) and an edited Live Photo's video (`epv`). The RAW is part of the
    /// photo, so failing to read it fails the export; the edit's extras only refine a restore and are skipped with a
    /// warning. `allowNetwork: false` uses only what's on the device (never iCloud Photos).
    func exportExtras(of asset: PHAsset, into directory: URL, edit: Bool, allowNetwork: Bool = true,
                      skip: Set<CaptionMeta.Role> = []) async throws -> [ExportedExtra] {
        let resources = PHAssetResource.assetResources(for: asset)
        let base = UUID().uuidString
        var out: [ExportedExtra] = []
        func export(_ r: PHAssetResource, role: CaptionMeta.Role) async throws {
            let url = directory.appendingPathComponent("\(base)-\(role.rawValue)-\(r.originalFilename.sanitizedFilename)")
            try await write(r, to: url, allowNetwork: allowNetwork)
            out.append(ExportedExtra(role: role, url: url, filename: r.originalFilename))
        }
        do {
            if asset.mediaType == .image, !skip.contains(.rawAlternate), resources.contains(where: { $0.type == .photo }),
               let raw = resources.first(where: { $0.type == .alternatePhoto }) {
                try await export(raw, role: .rawAlternate)
            }
        } catch {
            for e in out { try? FileManager.default.removeItem(at: e.url) }
            throw error
        }
        guard edit else { return out }
        // Photos names them Adjustments.plist and AdjustmentsSecondary.data.
        let adjustments = resources.filter { $0.type == .adjustmentData }
        let main = adjustments.first { $0.originalFilename.lowercased().hasSuffix(".plist") } ?? adjustments.first
        let secondary = adjustments.first { $0 !== main }
        let editedVideo = asset.mediaSubtypes.contains(.photoLive) ? resources.first { $0.type == .fullSizePairedVideo } : nil
        let edits: [(PHAssetResource?, CaptionMeta.Role)] = [(main, .adjustment), (secondary, .adjustmentSecondary), (editedVideo, .editedPairedVideo)]
        for (resource, role) in edits {
            guard let resource, !skip.contains(role) else { continue }
            do { try await export(resource, role: role) } catch {
                AppLog.shared.warn("Couldn't export \(role.rawValue) of \(asset.localIdentifier.prefix(8)): \(error.localizedDescription)")
            }
        }
        return out
    }

    /// Writes one resource (e.g. the edited version) into `directory`.
    /// `allowNetwork`: false fails instead of downloading the resource from iCloud Photos.
    func exportResource(_ resource: PHAssetResource, into directory: URL, allowNetwork: Bool = true) async throws -> URL {
        let url = directory.appendingPathComponent("\(UUID().uuidString)-\(resource.originalFilename.sanitizedFilename)")
        try await write(resource, to: url, allowNetwork: allowNetwork)
        return url
    }

    /// The rendered edit of an edited asset (`fullSizePhoto` / `fullSizeVideo`), nil if never edited.
    func editedResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        let original = resources.contains { $0.type == .photo || $0.type == .video }
        guard original else { return nil } // only a rendered version exists: that's already the primary
        let type: PHAssetResourceType = asset.mediaType == .video ? .fullSizeVideo : .fullSizePhoto
        return resources.first { $0.type == type }
    }

    /// The fast version of a video (role `sp`) from what Photos plays: edits and slow motion applied.
    func exportStreamingCopy(of asset: PHAsset, to url: URL) async throws -> (url: URL, width: Int, height: Int) {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        options.deliveryMode = .highQualityFormat
        let source: AVAsset? = await withCheckedContinuation { cont in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { a, _, _ in cont.resume(returning: a) }
        }
        guard let source else { throw PhotoLibraryError.noOriginalResource }
        return try await StreamingCopyEncoder.encode(source, to: url)
    }

    private func renderedImageData(of asset: PHAsset) async throws -> (Data, String?) {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current
        return try await withCheckedThrowingContinuation { cont in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, info in
                if let data { cont.resume(returning: (data, uti)) }
                else { cont.resume(throwing: (info?[PHImageErrorKey] as? Error) ?? PhotoLibraryError.noOriginalResource) }
            }
        }
    }

    private func write(_ resource: PHAssetResource, to url: URL, allowNetwork: Bool = true) async throws {
        try? FileManager.default.removeItem(at: url)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    // MARK: - Images

    func image(for asset: PHAsset, targetSize: CGSize, mode: PHImageRequestOptionsDeliveryMode = .highQualityFormat) async -> PlatformImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = mode
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { cont in
            var resumed = false
            PHImageManager.default().requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFit, options: options) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if degraded && mode == .highQualityFormat { return }
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: image)
            }
        }
    }

    /// ~320 px JPEG under 60 KB for the cloud thumbnail.
    func thumbnailJPEG(for asset: PHAsset) async -> Data? {
        guard let image = await image(for: asset, targetSize: CGSize(width: 320, height: 320)) else { return nil }
        return Self.compressedJPEG(image, maxPixel: 320, maxBytes: 60_000)
    }

    static func compressedJPEG(_ image: PlatformImage, maxPixel: CGFloat, maxBytes: Int) -> Data? {
        var side = maxPixel
        while side >= 80 {
            let scaled = image.scaledToFit(maxPixel: side)
            for quality in stride(from: 0.75, through: 0.3, by: -0.15) {
                if let data = scaled.jpegData(compressionQuality: quality), data.count <= maxBytes { return data }
            }
            side *= 0.8
        }
        return image.scaledToFit(maxPixel: 80).jpegData(compressionQuality: 0.3)
    }

    // MARK: - Changes

    func deleteAssets(_ identifiers: [String]) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }

    /// Saves a downloaded original back into Photos, restoring date and location. Returns the new local identifier.
    func saveToPhotos(item: MediaItem, primary: URL, pairedVideo: URL?) async throws -> String? {
        var placeholderId: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = item.filename
            switch item.kind {
            case .video:
                request.addResource(with: .video, fileURL: primary, options: options)
            case .photo:
                request.addResource(with: .photo, fileURL: primary, options: options)
            case .livePhoto:
                request.addResource(with: .photo, fileURL: primary, options: options)
                if let pairedVideo {
                    let videoOptions = PHAssetResourceCreationOptions()
                    videoOptions.originalFilename = item.pairedVideoFilename
                    request.addResource(with: .pairedVideo, fileURL: pairedVideo, options: videoOptions)
                }
            }
            request.creationDate = item.creationDate
            if let lat = item.latitude, let lon = item.longitude {
                request.location = CLLocation(latitude: lat, longitude: lon)
            }
            placeholderId = request.placeholderForCreatedAsset?.localIdentifier
        }
        return placeholderId
    }
}

#if os(iOS)
extension UIImage {
    func scaledToFit(maxPixel: CGFloat) -> UIImage {
        let pixelW = size.width * scale, pixelH = size.height * scale
        let ratio = min(1, maxPixel / max(pixelW, pixelH))
        let target = CGSize(width: max(1, (pixelW * ratio).rounded()), height: max(1, (pixelH * ratio).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
#endif

extension String {
    var sanitizedFilename: String {
        let cleaned = components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r")).joined(separator: "_")
        return cleaned.isEmpty ? "file" : cleaned
    }

    var mimeTypeForFilename: String {
        let ext = (self as NSString).pathExtension
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }
}

import AVFoundation

/// Codec and HDR flavour of a video, for the caption (`c`, `hdr`).
enum VideoInfo {
    struct Result { let codec: String?; let hdr: Int }

    static func inspect(asset: PHAsset) async -> Result? {
        guard asset.mediaType == .video else { return nil }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .original
        let avAsset: AVAsset? = await withCheckedContinuation { cont in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { a, _, _ in cont.resume(returning: a) }
        }
        guard let avAsset, let track = try? await avAsset.loadTracks(withMediaType: .video).first,
              let formats = try? await track.load(.formatDescriptions), let desc = formats.first else { return nil }
        let subtype = CMFormatDescriptionGetMediaSubType(desc)
        let codec: String?
        switch subtype {
        case kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVCWithAlpha: codec = "hevc"
        case kCMVideoCodecType_H264: codec = "h264"
        case kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ, kCMVideoCodecType_AppleProRes422LT,
             kCMVideoCodecType_AppleProRes422Proxy, kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes4444XQ:
            codec = "prores"
        case 0x64766831 /* dvh1 */, 0x64766865 /* dvhe */: codec = "hevc"
        default: codec = nil
        }
        var hdr = 0
        let characteristics = (try? await track.load(.mediaCharacteristics)) ?? []
        if characteristics.contains(.containsHDRVideo) { hdr = 1 }
        if subtype == 0x64766831 || subtype == 0x64766865 { hdr = 2 }
        if let ext = CMFormatDescriptionGetExtensions(desc) as? [String: Any],
           let atoms = ext["SampleDescriptionExtensionAtoms"] as? [String: Any], atoms["dvcC"] != nil || atoms["dvvC"] != nil {
            hdr = 2
        }
        return Result(codec: codec, hdr: hdr)
    }
}
