import Foundation
import Photos
import Vision
import CoreLocation
import MemvoCore

/// On-device search (#14). Vision reads each photo once (text in it, and things and scenes) into the local database;
/// places come from the photo's location, dates and kinds from the timeline itself. Photos are read on the device and
/// never sent anywhere. Place names are looked up once per ~1 km area with Apple's geocoder, which receives only that
/// rounded location.
final class SearchService: @unchecked Sendable {
    private let store: LibraryStore
    private let photos: PhotoLibraryService
    private let media: () -> CloudMediaService
    private let lock = NSLock()
    private var running = false
    private var places: [String: String]?
    private var _status: (indexed: Int, total: Int) = (0, 0)
    /// (read, to read) of the last indexing pass, for Search's footer.
    var status: (indexed: Int, total: Int) {
        get { lock.withLock { _status } }
        set { lock.withLock { _status = newValue } }
    }

    static let didIndex = Notification.Name("Memvo.searchDidIndex")

    init(store: LibraryStore, photos: PhotoLibraryService, media: @escaping () -> CloudMediaService) {
        self.store = store
        self.photos = photos
        self.media = media
    }

    // MARK: - Query

    /// The inverted index of every entry's words, built once per library change so typing is a lookup.
    func index(for entries: [GalleryEntry]) -> SearchIndex {
        let indexed = (try? store.searchWords()) ?? [:]
        let places = loadPlaces()
        return SearchIndex(entries: entries.map { e in
            var known = SearchMatcher.dateWords(e.date)
            if let words = indexed[e.id] { known += words.split(separator: " ").map(String.init) }
            if let cell = Self.cell(e), let place = places[cell] { known += SearchMatcher.words(place) }
            if let item = e.item {
                known += SearchMatcher.words(((item.albums ?? []) + [item.filename]).joined(separator: " "))
            }
            known += Self.kindWords(e)
            return (e.id, known)
        })
    }

    /// Suggestions under an empty search field, like Ente's: the places with the most photos, and recent months.
    func suggestions(for entries: [GalleryEntry], limit: Int = 10) -> (places: [String], months: [String]) {
        let places = loadPlaces()
        var placeCounts: [String: Int] = [:]
        var monthCounts: [String: Int] = [:]
        var monthOrder: [String] = []
        let month = DateFormatter()
        month.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        for e in entries {
            if let cell = Self.cell(e), let name = places[cell]?.split(separator: ",").first {
                placeCounts[name.trimmingCharacters(in: .whitespaces), default: 0] += 1
            }
            if let date = e.date, monthOrder.count < limit || monthCounts[month.string(from: date)] != nil {
                let m = month.string(from: date)
                if monthCounts[m] == nil { monthOrder.append(m) }
                monthCounts[m, default: 0] += 1
            }
        }
        return (placeCounts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(limit).map(\.key), Array(monthOrder.prefix(limit)))
    }

    private static func cell(_ e: GalleryEntry) -> String? {
        if let loc = e.asset?.location { return SearchMatcher.placeCell(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude) }
        if let item = e.item, let lat = item.latitude, let lon = item.longitude { return SearchMatcher.placeCell(latitude: lat, longitude: lon) }
        return nil
    }

    private static func kindWords(_ e: GalleryEntry) -> [String] {
        var out: [String] = []
        if e.isVideo { out += ["video", "videos"] }
        if e.isLive { out += ["live", "photo"] }
        if !e.isVideo { out += ["photo", "photos"] }
        if e.asset?.isFavorite == true || e.item?.favorite == true { out += ["favorite", "favourite", "favorites"] }
        if let a = e.asset {
            if a.mediaSubtypes.contains(.photoScreenshot) { out += ["screenshot", "screenshots"] }
            if a.mediaSubtypes.contains(.photoPanorama) { out += ["panorama"] }
        }
        return out
    }

    // MARK: - Indexing

    /// Reads photos not read yet (or edited since) until done or `isCancelled`. One pass at a time.
    func index(isCancelled: @escaping @Sendable () -> Bool) async {
        let start: Bool = lock.withLock {
            if running { return false }
            running = true
            return true
        }
        guard start else { return }
        defer { lock.withLock { running = false } }
        guard PhotoLibraryService.hasAccess || !((try? store.items(status: .backedUp)) ?? []).isEmpty else { return }
        let started = Date()

        // What the timeline shows: phone photos, and cloud items not on this device.
        var work: [(key: String, stamp: String, asset: PHAsset?, item: MediaItem?)] = []
        var present = Set<String>()
        if PhotoLibraryService.hasAccess {
            photos.fetchAllAssets().enumerateObjects { a, _, _ in
                present.insert(a.localIdentifier)
                work.append((a.localIdentifier, "p\(Int64(a.modificationDate?.timeIntervalSince1970 ?? 0))", a, nil))
            }
        }
        for item in (try? store.items(status: .backedUp)) ?? [] where item.hidden != true && (item.localIdentifier.map { !present.contains($0) } ?? true) {
            work.append(("cloud-\(item.id)", "c", nil, item))
        }
        let stamps = (try? store.searchStamps()) ?? [:]
        // Entries that are gone from the timeline leave the index.
        let keys = Set(work.map(\.key))
        try? store.deleteSearch(keys: stamps.keys.filter { !keys.contains($0) })
        let todo = work.filter { stamps[$0.key] != $0.stamp }
        status = (work.count - todo.count, work.count)
        // Place names come from the network, photos from the device: both at once.
        let places = Task.detached(priority: .utility) { [self] in await lookUpPlaces(isCancelled: isCancelled) }

        var done = 0
        for entry in todo {
            if isCancelled() || Task.isCancelled { break }
            let image: CGImage?
            if let asset = entry.asset {
                image = await phoneImage(asset)
            } else if let item = entry.item, let thumb = try? await media().thumbnail(for: item, urgent: false) {
                image = Self.cgImage(thumb)
            } else {
                image = nil
            }
            let words = image.map(Self.read) ?? ""
            try? store.setSearch(key: entry.key, stamp: entry.stamp, words: words)
            done += 1
            status = (work.count - todo.count + done, work.count)
            if done % 50 == 0 { NotificationCenter.default.post(name: Self.didIndex, object: nil) }
            // On battery, leave room for everything else the phone is doing.
            if !Device.isCharging { try? await Task.sleep(nanoseconds: 50_000_000) }
        }
        if Task.isCancelled { places.cancel() }
        await places.value
        NotificationCenter.default.post(name: Self.didIndex, object: nil)
        if done > 0 { NotificationCenter.default.post(name: Self.didIndex, object: nil) }
        appLog(String(format: "Search index: read %d of %d new photos (%d of %d indexed) in %.0f s",
                      done, todo.count, status.indexed, status.total, Date().timeIntervalSince(started)))
    }

    private var foreground: Task<Void, Never>?

    /// While the app is open, as Ente and Immich read photos for search: at low priority, a short pause between photos
    /// when not charging, and not at all in Low Power Mode. `stopForeground` when the app leaves the screen.
    func indexInForeground() {
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        lock.withLock {
            guard foreground == nil else { return }
            foreground = Task.detached(priority: .utility) { [self] in
                await index(isCancelled: { ProcessInfo.processInfo.isLowPowerModeEnabled })
                lock.withLock { foreground = nil }
            }
        }
    }

    func stopForeground() {
        lock.withLock {
            foreground?.cancel()
            foreground = nil
        }
    }

    /// Text in the photo and the things and scenes Vision recognises, on the device.
    private static func read(_ image: CGImage) -> String {
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = true
        let things = VNClassifyImageRequest()
        try? VNImageRequestHandler(cgImage: image).perform([text, things])
        let lines = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let labels = (things.results ?? []).filter { $0.confidence >= 0.35 }.prefix(10).map(\.identifier)
        return SearchMatcher.storedWords(text: lines, things: Array(labels))
    }

    /// Big enough to read text in, from what's on the device (nothing is downloaded from iCloud Photos for this).
    private func phoneImage(_ asset: PHAsset) async -> CGImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        return await withCheckedContinuation { cont in
            var resumed = false
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 1024, height: 1024), contentMode: .aspectFit,
                                                  options: options) { image, _ in
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: image.flatMap(Self.cgImage))
            }
        }
    }

    private static func cgImage(_ image: PlatformImage) -> CGImage? {
        #if os(macOS)
        image.cgImageValue
        #else
        image.cgImage
        #endif
    }

    // MARK: - Places

    private var placesURL: URL { AppPaths.caches.appendingPathComponent("search-places.json") }

    private func loadPlaces() -> [String: String] {
        lock.withLock {
            if let places { return places }
            let loaded = (try? Data(contentsOf: placesURL)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
            places = loaded
            return loaded
        }
    }

    /// Names for areas not looked up yet, one request at a time with a pause between, as Apple's geocoder asks.
    private func lookUpPlaces(isCancelled: @escaping @Sendable () -> Bool) async {
        var cells = Set<String>()
        var coords: [String: CLLocation] = [:]
        func add(_ lat: Double, _ lon: Double) {
            let cell = SearchMatcher.placeCell(latitude: lat, longitude: lon)
            // Apple's geocoder gets the middle of the ~1 km area, never a photo's own location.
            if cells.insert(cell).inserted { coords[cell] = CLLocation(latitude: (lat * 100).rounded() / 100, longitude: (lon * 100).rounded() / 100) }
        }
        if PhotoLibraryService.hasAccess {
            photos.fetchAllAssets().enumerateObjects { a, _, _ in
                if let c = a.location?.coordinate { add(c.latitude, c.longitude) }
            }
        }
        for item in (try? store.items(status: .backedUp)) ?? [] {
            if let lat = item.latitude, let lon = item.longitude { add(lat, lon) }
        }
        var known = loadPlaces()
        let missing = cells.filter { known[$0] == nil }
        guard !missing.isEmpty, NetworkStatus.shared.isOnline else { return }
        let geocoder = CLGeocoder()
        var found = 0
        for cell in missing {
            if isCancelled() || Task.isCancelled { break }
            guard let location = coords[cell] else { continue }
            if let mark = try? await geocoder.reverseGeocodeLocation(location).first {
                let parts = [mark.locality ?? mark.subAdministrativeArea, mark.administrativeArea, mark.country]
                    + (mark.areasOfInterest ?? []) + [mark.subLocality]
                known[cell] = parts.compactMap { $0 }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ", ")
                found += 1
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
        }
        lock.withLock { places = known }
        if let data = try? JSONEncoder().encode(known) { try? data.write(to: placesURL, options: .atomic) }
        if found > 0 { appLog("Search index: named \(found) of \(missing.count) new places") }
    }
}
