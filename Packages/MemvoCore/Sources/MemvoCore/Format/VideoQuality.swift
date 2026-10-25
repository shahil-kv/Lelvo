import Foundation

/// Which stored version of a cloud video plays.
public enum VideoQuality: String, Sendable {
    /// The original (or its edit, role `e`): full resolution, full bitrate.
    case original
    /// The fast version (role `sp`): at most 1080p, ~2.5 Mbit/s.
    case streamingCopy
}

/// The user's setting for cloud video playback.
public enum VideoQualityPreference: String, CaseIterable, Sendable {
    /// Fast version on mobile data or a slow connection, original otherwise.
    case automatic
    /// Always the original, even if it buffers.
    case original
}

/// When to make a fast version (role `sp`) of a video. Telegram sends free accounts about 1 MB/s (8 Mbit/s), while
/// iPhone videos are 15–60 Mbit/s, so originals can't stream smoothly. Like Ente's streams (720p, 2 Mbit/s), the fast
/// version is small enough to play at once at that speed. Videos that already stream fine are skipped.
public enum StreamingCopyPolicy {
    /// The fast version's video bitrate: a third of Telegram's typical speed, so it never waits.
    public static let targetBitsPerSecond: Double = 2_500_000
    /// Below this the original streams about as easily as a fast version would.
    public static let minimumBitsPerSecond: Double = 4_000_000
    /// Smaller videos load in a moment anyway.
    public static let minimumBytes: Int64 = 4 << 20
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
    /// Until playback has measured the connection: about what Telegram sends free accounts.
    public static let assumedBytesPerSecond: Double = 1_000_000
    /// The original paused to load for this long while playing: switch to the copy (Automatic only).
    public static let stallSecondsBeforeFallback: TimeInterval = 3

    public static func initial(preference: VideoQualityPreference, hasCopy: Bool, isExpensiveNetwork: Bool,
                               bytesPerSecond: Double?, originalBitsPerSecond: Double?) -> VideoQuality {
        guard hasCopy, preference == .automatic else { return .original }
        if isExpensiveNetwork { return .streamingCopy }
        // Wi-Fi: the original when the connection (measured, else Telegram's usual speed) keeps up with it.
        if let needed = originalBitsPerSecond, (bytesPerSecond ?? assumedBytesPerSecond) * 8 < needed * speedMargin {
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
    /// A fast version is stored with all of its parts.
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
