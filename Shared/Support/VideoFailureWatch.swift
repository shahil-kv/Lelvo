import AVFoundation

/// Calls `onFailure` on the main queue when a player item can't play. Without it a video that fails to open shows a black
/// screen and one log line; the viewers use this to open it once more, then to offer "Try again".
final class VideoFailureWatch {
    private var observation: NSKeyValueObservation?

    init(item: AVPlayerItem, onFailure: @escaping (NSError?) -> Void) {
        observation = item.observe(\.status, options: [.new]) { item, _ in
            guard item.status == .failed else { return }
            let error = item.error as NSError?
            DispatchQueue.main.async { onFailure(error) }
        }
    }
}
