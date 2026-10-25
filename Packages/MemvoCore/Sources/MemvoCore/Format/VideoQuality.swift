import Foundation

/// Which stored version of a cloud video plays.
public enum VideoQuality: String, Sendable {
    /// The original (or its edit, role `e`): full resolution, full bitrate.
    case original
    /// The 1080p copy (role `sp`).
    case streamingCopy
}

/// The user's setting for cloud video playback.
public enum VideoQualityPreference: String, CaseIterable, Sendable {
    /// Streaming copy on mobile data or a slow connection, original otherwise.
    case automatic
    /// Always the original, even if it buffers.
    case original
}

/// When to make a streaming copy (role `sp`) of a video. Like Ente's stream generation, small or already
/// low-bitrate videos are skipped: they stream fine as they are and a copy would save little.
public enum StreamingCopyPolicy {
    /// About 1.5× what a 1080p HEVC copy needs; below this the original streams as easily as a copy would.
    public static let minimumBitsPerSecond: Double = 12_000_000
    /// Smaller videos load in a moment even on mobile data.
    public static let minimumBytes: Int64 = 20 << 20
    /// A copy at least this much smaller than the original is worth storing.
    public static let maximumSizeRatio = 0.7

    public static func shouldMake(_ item: MediaItem) -> Bool {
        guard item.kind == .video, item.fileSize >= minimumBytes, let bits = item.originalBitsPerSecond else { return false }
        let longSide = max(item.pixelWidth, item.pixelHeight), shortSide = min(item.pixelWidth, item.pixelHeight)
        return bits > minimumBitsPerSecond || longSide > 1920 || shortSide > 1080
    }

    public static func isWorthKeeping(copyBytes: Int64, originalBytes: Int64) -> Bool {
        copyBytes > 0 && Double(copyBytes) < Double(originalBytes) * maximumSizeRatio
    }
}

/// Picks the version to play when a cloud video opens, and when to fall back to the copy while playing.
public enum VideoQualityPolicy {
    /// The original must arrive at least this much faster than it plays, or it would keep stopping to load.
    public static let speedMargin = 1.3
    /// The original paused to load for this long while playing: switch to the copy (Automatic only).
    public static let stallSecondsBeforeFallback: TimeInterval = 3

    public static func initial(preference: VideoQualityPreference, hasCopy: Bool, isExpensiveNetwork: Bool,
                               bytesPerSecond: Double?, originalBitsPerSecond: Double?) -> VideoQuality {
        guard hasCopy, preference == .automatic else { return .original }
        if isExpensiveNetwork { return .streamingCopy }
        // Wi-Fi: original unless the connection measured so far is clearly too slow for it.
        if let speed = bytesPerSecond, let needed = originalBitsPerSecond, speed * 8 < needed * speedMargin {
            return .streamingCopy
        }
        return .original
    }

    /// Whether a stall while playing the original should switch to the copy. Never overrides the user's own
    /// choice in the viewer or the Original setting.
    public static func fallsBackOnStall(playing: VideoQuality, preference: VideoQualityPreference,
                                        hasCopy: Bool, userChose: Bool) -> Bool {
        playing == .original && preference == .automatic && hasCopy && !userChose
    }
}

/// Download speed from the bytes playback already fetches (no test traffic): an exponentially weighted average
/// of reads that actually waited for the network.
public struct ThroughputEstimator: Sendable {
    /// Reads served from what's already downloaded return instantly and say nothing about the connection.
    public static let minimumSeconds = 0.15
    public static let minimumBytes = 256 << 10
    private static let weight = 0.3
    public private(set) var bytesPerSecond: Double?

    public init() {}

    public mutating func add(bytes: Int, seconds: TimeInterval) {
        guard bytes >= Self.minimumBytes, seconds >= Self.minimumSeconds else { return }
        let sample = Double(bytes) / seconds
        bytesPerSecond = bytesPerSecond.map { $0 + Self.weight * (sample - $0) } ?? sample
    }
}

extension MediaItem {
    /// A 1080p copy is stored with all of its parts.
    public var hasStreamingCopy: Bool {
        let have = parts("sp").count
        return have > 0 && have == (expectedParts?["sp"] ?? 1)
    }

    /// Average bitrate of the original, from its size and duration.
    public var originalBitsPerSecond: Double? {
        guard let duration, duration > 0, fileSize > 0 else { return nil }
        return Double(fileSize) * 8 / duration
    }
}
