import Foundation
import Photos
import Vision
import LelvoCore

/// Finds near-identical photos (bursts, several shots of one thing) with Vision's on-device feature prints, for
/// Duplicates review. Like Ente, the whole library is compared: photos on this device from a small image of each,
/// cloud-only ones from their thumbnail. Nothing leaves the device. Prints are kept in the caches folder per photo
/// version, so looking again only reads new photos.
final class SimilarPhotosService: @unchecked Sendable {
    struct Group: Identifiable {
        let entries: [GalleryEntry]
        let best: String
        var id: String { entries.first?.id ?? best }
    }

    private let photos: PhotoLibraryService
    private let store: LibraryStore
    private let media: () -> CloudMediaService
    private let lock = NSLock()
    private var prints: [String: VNFeaturePrintObservation] = [:]
    private var printsLoaded = false

    init(photos: PhotoLibraryService, store: LibraryStore, media: @escaping () -> CloudMediaService) {
        self.photos = photos
        self.store = store
        self.media = media
    }

    private var cacheURL: URL { AppPaths.caches.appendingPathComponent("similar-feature-prints.data") }

    private var current: Task<[Group], Never>?

    /// Groups of similar photos, newest first. `progress` reports (compared, to compare) every few photos. One pass at
    /// a time: asking again while one runs waits for it, and cancelling the caller (leaving the screen) stops it.
    func find(progress: @escaping @Sendable (Int, Int) -> Void) async -> [Group] {
        let task: Task<[Group], Never> = lock.withLock {
            if let current { return current }
            let t = Task.detached(priority: .utility) { [self] in await compare(progress: progress) }
            current = t
            return t
        }
        let groups = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        lock.withLock { if current == task { current = nil } }
        return groups
    }

    private func compare(progress: @escaping @Sendable (Int, Int) -> Void) async -> [Group] {
        let started = Date()
        var entries: [String: GalleryEntry] = [:]
        var versions: [String: String] = [:]
        var candidates: [SimilarPhotos.Candidate] = []
        var present = Set<String>()
        if PhotoLibraryService.hasAccess {
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            PHAsset.fetchAssets(with: options).enumerateObjects { a, _, _ in
                present.insert(a.localIdentifier)
                guard let date = a.creationDate, !a.mediaSubtypes.contains(.photoScreenshot) else { return }
                entries[a.localIdentifier] = GalleryEntry(id: a.localIdentifier, date: date, asset: a, item: nil)
                versions[a.localIdentifier] = "\(a.localIdentifier)|\(Int64(a.modificationDate?.timeIntervalSince1970 ?? 0))"
                candidates.append(.init(id: a.localIdentifier, date: date, pixels: a.pixelWidth * a.pixelHeight, favorite: a.isFavorite))
            }
        }
        for item in store.cloudOnlyItems(present: present) where item.kind != .video {
            guard let date = item.creationDate else { continue }
            let id = "cloud-\(item.id)"
            entries[id] = GalleryEntry(id: id, date: date, asset: nil, item: item)
            versions[id] = id
            candidates.append(.init(id: id, date: date, pixels: item.pixelWidth * item.pixelHeight, favorite: item.favorite == true))
        }
        let runs = SimilarPhotos.runs(candidates)
        let total = runs.reduce(0) { $0 + $1.count }
        loadPrints()
        progress(0, total)
        var done = 0, computed = 0
        var groups: [Group] = []
        for run in runs {
            if Task.isCancelled { break }
            var runPrints: [String: VNFeaturePrintObservation] = [:]
            for c in run {
                guard let entry = entries[c.id], let version = versions[c.id] else { continue }
                if let p = lock.withLock({ prints[version] }) {
                    runPrints[c.id] = p
                } else if let image = await smallImage(entry), let p = Self.featurePrint(image) {
                    lock.withLock { prints[version] = p }
                    runPrints[c.id] = p
                    computed += 1
                }
                done += 1
                if done % 10 == 0 || done == total { progress(done, total) }
            }
            for g in SimilarPhotos.groups(in: run, distance: { a, b in
                guard let x = runPrints[a.id], let y = runPrints[b.id] else { return nil }
                var d: Float = 0
                return (try? x.computeDistance(&d, to: y)) != nil ? d : nil
            }) {
                guard let best = SimilarPhotos.best(g) else { continue }
                // Phone photos get their backup record, so the screen can mark the ones not backed up.
                let members = g.compactMap { entries[$0.id] }.map { e in
                    e.asset == nil ? e : GalleryEntry(id: e.id, date: e.date, asset: e.asset, item: try? store.item(localIdentifier: e.id))
                }
                groups.append(Group(entries: members, best: best.id))
            }
        }
        // Only photos that can still be compared keep a print: deleted and edited ones drop out.
        let current = Set(runs.joined().compactMap { versions[$0.id] })
        let pruned: Bool = lock.withLock {
            let before = prints.count
            prints = prints.filter { current.contains($0.key) }
            return prints.count != before
        }
        if computed > 0 || pruned { savePrints() }
        appLog(String(format: "Similar photos: %d groups among %d candidates of %d photos (%d read now) in %.1f s",
                      groups.count, total, candidates.count, computed, Date().timeIntervalSince(started)))
        return groups.reversed()
    }

    private static func featurePrint(_ image: CGImage) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFill
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return request.results?.first
    }

    /// The grid's own thumbnail when it's cached; else a small image from the device, or the cloud thumbnail.
    private func smallImage(_ entry: GalleryEntry) async -> CGImage? {
        if let cached = ThumbnailPipeline.shared.cached(entry)?.image { return Self.cg(cached) }
        if let asset = entry.asset {
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false
            return await withCheckedContinuation { cont in
                var resumed = false
                PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 360, height: 360), contentMode: .aspectFit,
                                                      options: options) { image, _ in
                    guard !resumed else { return }
                    resumed = true
                    cont.resume(returning: image.flatMap(Self.cg))
                }
            }
        }
        guard let item = entry.item, let thumb = try? await media().thumbnail(for: item, urgent: false) else { return nil }
        return Self.cg(thumb)
    }

    private static func cg(_ image: PlatformImage) -> CGImage? {
        #if os(macOS)
        image.cgImageValue
        #else
        image.cgImage
        #endif
    }

    private func loadPrints() {
        lock.withLock {
            guard !printsLoaded else { return }
            printsLoaded = true
            guard let data = try? Data(contentsOf: cacheURL),
                  let dict = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSDictionary.self, NSString.self, VNFeaturePrintObservation.self], from: data)
                    as? [String: VNFeaturePrintObservation] else { return }
            prints = dict
        }
    }

    private func savePrints() {
        let snapshot = lock.withLock { prints } as NSDictionary
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: snapshot, requiringSecureCoding: true) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
