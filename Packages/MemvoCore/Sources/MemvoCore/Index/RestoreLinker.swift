import Foundation

/// What a restore needs to know about a photo on this device.
public struct AssetKey: Sendable {
    public let localIdentifier: String
    public let filename: String
    public let creationDate: Date?
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(localIdentifier: String, filename: String, creationDate: Date?, pixelWidth: Int, pixelHeight: Int) {
        self.localIdentifier = localIdentifier
        self.filename = filename
        self.creationDate = creationDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// Links restored cloud items to this device's photos after a reinstall, without re-reading any file:
/// first by the asset id recorded in the caption, then by original filename + capture second + pixel size.
/// Each asset and each item is linked at most once.
public enum RestoreLinker {
    /// Returns item id → asset local identifier.
    public static func match(unlinked: [MediaItem], assets: [AssetKey]) -> [String: String] {
        var links: [String: String] = [:]
        var used = Set<String>()
        let assetIds = Set(assets.map(\.localIdentifier))

        for item in unlinked {
            if let id = item.sourceLocalIdentifier, assetIds.contains(id), used.insert(id).inserted {
                links[item.id] = id
            }
        }

        var byKey: [String: String] = [:]
        for a in assets where !used.contains(a.localIdentifier) {
            guard let k = key(a.filename, a.creationDate, a.pixelWidth, a.pixelHeight) else { continue }
            if byKey[k] == nil { byKey[k] = a.localIdentifier }
        }
        for item in unlinked where links[item.id] == nil {
            guard let k = key(item.filename, item.creationDate, item.pixelWidth, item.pixelHeight),
                  let id = byKey.removeValue(forKey: k), used.insert(id).inserted else { continue }
            links[item.id] = id
        }
        return links
    }

    /// Seconds truncated exactly like the caption `t` field.
    private static func key(_ name: String, _ date: Date?, _ w: Int, _ h: Int) -> String? {
        guard let date, !name.isEmpty, w > 0, h > 0 else { return nil }
        return "\(name.lowercased())|\(shape(date, w, h))"
    }

    private static func shape(_ date: Date, _ w: Int, _ h: Int) -> String {
        "\(Int64(date.timeIntervalSince1970))|\(w)x\(h)"
    }

    /// Which photos can link to any of `unlinked` at all: by the asset id in a caption, or by capture second and pixel
    /// size, which a `PHAsset` knows. Looking up a photo's file name loads its resource records, slow over a whole
    /// library (many seconds for 50k photos), so it's only done for photos with a matching capture second and size.
    /// `match` then links exactly as it would with every file name known.
    public struct Prefilter: Sendable {
        let ids: Set<String>
        let shapes: Set<String>

        public init(unlinked: [MediaItem]) {
            ids = Set(unlinked.compactMap(\.sourceLocalIdentifier))
            shapes = Set(unlinked.compactMap { item in
                guard let date = item.creationDate, !item.filename.isEmpty, item.pixelWidth > 0, item.pixelHeight > 0 else { return nil }
                return shape(date, item.pixelWidth, item.pixelHeight)
            })
        }

        /// A caption names this photo: it links by id, so its file name isn't needed.
        public func linksById(_ localIdentifier: String) -> Bool { ids.contains(localIdentifier) }

        /// The photo's file name is needed (it may link by name, capture second and size).
        public func needsFilename(creationDate: Date?, pixelWidth: Int, pixelHeight: Int) -> Bool {
            guard let creationDate, pixelWidth > 0, pixelHeight > 0 else { return false }
            return shapes.contains(shape(creationDate, pixelWidth, pixelHeight))
        }
    }
}
