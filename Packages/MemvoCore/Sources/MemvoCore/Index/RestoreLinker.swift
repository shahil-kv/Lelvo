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
        return "\(name.lowercased())|\(Int64(date.timeIntervalSince1970))|\(w)x\(h)"
    }
}
