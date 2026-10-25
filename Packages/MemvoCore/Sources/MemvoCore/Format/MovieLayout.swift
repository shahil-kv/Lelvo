import Foundation

/// Top-level boxes of an MP4/QuickTime file, read from its first bytes. iPhone camera videos store the `moov`
/// index after the media data, so a player reads the start, then the end, then the start again; knowing where
/// `moov` is lets the app fetch both ends ahead of time.
public enum MovieLayout {
    /// Byte range of the `moov` box when it comes after `mdat`, found from `prefix` (the file's first bytes).
    /// Nil when `moov` is at the start (already covered by the prefix) or the layout can't be read.
    public static func trailingIndexRange(prefix: Data, totalSize: Int64) -> Range<Int64>? {
        var offset: Int64 = 0
        while offset + 8 <= totalSize {
            // Box headers past the prefix: the box after the last fully known one is the candidate.
            guard offset + 8 <= Int64(prefix.count) else { return offset < totalSize ? offset..<totalSize : nil }
            let base = prefix.startIndex + Int(offset)
            var size = Int64(prefix[base..<base + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            let type = String(decoding: prefix[base + 4..<base + 8], as: UTF8.self)
            if size == 1 {
                guard offset + 16 <= Int64(prefix.count) else { return nil }
                size = Int64(prefix[base + 8..<base + 16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
            } else if size == 0 {
                size = totalSize - offset
            }
            guard size >= 8 else { return nil }
            if type == "moov" {
                // In the prefix already: nothing extra to fetch.
                return offset + size <= Int64(prefix.count) ? nil : offset..<min(totalSize, offset + size)
            }
            offset += size
        }
        return nil
    }
}
