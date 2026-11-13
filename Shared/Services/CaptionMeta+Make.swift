import Foundation
import LelvoCore

extension CaptionMeta {
    /// The caption fields backup and Takeout import both write. `src` is filled in by the uploader.
    static func make(for item: MediaItem, role: Role, hash: String, name: String, size: Int64) -> CaptionMeta {
        let kind: CaptionMeta.Kind = item.kind == .livePhoto ? .live : (item.kind == .video ? .video : .photo)
        var meta = CaptionMeta(id: item.id, role: role, kind: kind, sha256: hash, name: name, size: size)
        meta.m = name.mimeTypeForFilename
        meta.t = item.creationDate.map { Int64($0.timeIntervalSince1970) }
        meta.tz = item.tzOffsetMinutes
        if let lat = item.latitude, let lon = item.longitude { meta.g = CaptionMeta.roundedGPS(lat, lon) }
        if item.pixelWidth > 0 { meta.wh = [item.pixelWidth, item.pixelHeight] }
        meta.d = role == .thumbnail ? nil : item.duration
        meta.c = item.codec
        meta.hdr = item.hdr
        meta.a = item.albums
        meta.fav = item.favorite == true ? 1 : nil
        meta.l = item.localIdentifier
        meta.ed = (role == .original && item.hasEdit == true) ? 1 : nil
        meta.hid = item.hidden == true ? 1 : nil
        return meta
    }
}
