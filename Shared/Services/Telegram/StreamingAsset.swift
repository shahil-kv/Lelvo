import Foundation
import AVFoundation
import UniformTypeIdentifiers
import MemvoCore

/// Serves AVPlayer byte-range requests from Telegram through `MediaReader`, so videos start in a
/// second or two and seek instantly (including MOVs whose `moov` atom is at the end).
final class StreamingAsset: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "cgstream"

    let asset: AVURLAsset
    private let item: MediaItem
    private let role: String
    private let reader: MediaReader
    private let queue = DispatchQueue(label: "memvo.streaming")
    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var plaintextSize: Int64?
    private let opened = Date()
    private var firstDataLogged = false

    /// AVPlayer gets data in pieces of this size: small, so the first frame can show as soon as the start of the file
    /// arrives (at Telegram's ~1 MB/s a 1 MB piece alone took 1.5 s), and memory stays flat for multi-GB files.
    private static let slice: Int64 = 256 << 10
    private static let startSlice: Int64 = 64 << 10
    private static let startRegion: Int64 = 1 << 20

    init(item: MediaItem, role: String = "o", reader: MediaReader) {
        self.item = item
        self.role = role
        self.reader = reader
        let name = role == "pv" ? (item.pairedVideoFilename ?? "video.mov") : role == "e" ? (item.editedFilename ?? item.filename)
            : role == "sp" ? "copy.mp4" : item.filename
        let ext = (name as NSString).pathExtension.isEmpty ? "mov" : (name as NSString).pathExtension.lowercased()
        var parts = URLComponents()
        parts.scheme = Self.scheme
        parts.host = "item"
        // Unique per player: AVFoundation reuses state for an identical URL, so reopening a video whose
        // previous loader is gone failed with -11870 and took ~9 s to recover.
        parts.path = "/\(item.id)/\(UUID().uuidString)/\(role).\(ext)"
        let url = parts.url ?? URL(fileURLWithPath: "/\(item.id).\(ext)")
        asset = AVURLAsset(url: url)
        super.init()
        asset.resourceLoader.setDelegate(self, queue: queue)
        reader.streamOpened(item, role: role)
        // Find the file while AVPlayer sets up, instead of when it first asks for data; the timing log shows each step
        // of a cold start (Telegram connection, file lookup, first data, first frame in `VideoTrace`).
        let title = item.filename, opened = self.opened
        Task.detached(priority: .userInitiated) { [reader, item, role] in
            try? await TDService.shared.waitUntilReady(timeout: 30)
            let ready = Date().timeIntervalSince(opened)
            let lookup = await reader.warmUp(item, role: role)
            appLog(String(format: "Video timing: %@ [%@]: Telegram ready %.2f s, file found +%.2f s", title, role, ready, lookup))
        }
    }

    deinit {
        cancel()
        reader.streamClosed(item, role: role)
    }

    /// Stops every request in flight now (they'd otherwise finish downloading before the asset goes away).
    func cancel() {
        lock.withLock { tasks.values.forEach { $0.cancel() } }
    }

    private var contentType: String {
        let ext = asset.url.pathExtension
        return UTType(filenameExtension: ext)?.identifier ?? UTType.quickTimeMovie.identifier
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        let key = ObjectIdentifier(loadingRequest)
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.serve(loadingRequest)
                if !Task.isCancelled { loadingRequest.finishLoading() }
            } catch {
                // The player cancels requests when seeking or closing; only real failures are logged.
                if !(error is CancellationError) && !Task.isCancelled {
                    AppLog.shared.error("Streaming \(self.item.filename) failed: \(error.localizedDescription)")
                }
                if !Task.isCancelled { loadingRequest.finishLoading(with: error) }
            }
            _ = self.lock.withLock { self.tasks.removeValue(forKey: key) }
        }
        lock.withLock { tasks[key] = task }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        let task = lock.withLock { tasks.removeValue(forKey: ObjectIdentifier(loadingRequest)) }
        task?.cancel()
    }

    private func size() async throws -> Int64 {
        if let s = lock.withLock({ plaintextSize }) { return s }
        let s = try await reader.plaintextSize(item, role: role)
        lock.withLock { plaintextSize = s }
        return s
    }

    private func serve(_ request: AVAssetResourceLoadingRequest) async throws {
        try await TDService.shared.waitUntilReady(timeout: 30)
        let total = try await size()
        if let info = request.contentInformationRequest {
            info.contentType = contentType
            info.contentLength = total
            info.isByteRangeAccessSupported = true
        }
        guard let data = request.dataRequest else { return }
        let start = data.currentOffset != 0 ? data.currentOffset : data.requestedOffset
        let end = data.requestsAllDataToEndOfResource ? total : min(total, data.requestedOffset + Int64(data.requestedLength))
        var offset = start
        while offset < end {
            try Task.checkCancellation()
            let started = Date()
            // Small pieces at the start of the file: the index and first frame reach the player as soon as Telegram's
            // first bytes arrive, instead of after a whole slice.
            let piece = offset < Self.startRegion ? Self.startSlice : Self.slice
            let chunk = try await reader.read(item, role: role, range: offset ..< min(end, offset + piece), streaming: true)
            if chunk.isEmpty { break }
            StreamingThroughput.shared.record(bytes: chunk.count, seconds: Date().timeIntervalSince(started))
            data.respond(with: chunk)
            let first: Bool = lock.withLock {
                defer { firstDataLogged = true }
                return !firstDataLogged
            }
            if first {
                appLog(String(format: "Video timing: %@ [%@]: first data (%@ at %lld) after %.2f s",
                              item.filename, role, Format.bytes(Int64(chunk.count)), offset, Date().timeIntervalSince(opened)))
            }
            offset += Int64(chunk.count)
        }
    }
}

/// Download speed seen by playback, kept separately for Wi-Fi and mobile data, to choose a video quality.
final class StreamingThroughput: @unchecked Sendable {
    static let shared = StreamingThroughput()
    private let lock = NSLock()
    private var byNetwork: [Bool: ThroughputEstimator] = [:]

    func record(bytes: Int, seconds: TimeInterval) {
        let expensive = NetworkStatus.shared.isExpensive
        lock.withLock { byNetwork[expensive, default: ThroughputEstimator()].add(bytes: bytes, seconds: seconds) }
    }

    var bytesPerSecond: Double? {
        let expensive = NetworkStatus.shared.isExpensive
        return lock.withLock { byNetwork[expensive]?.bytesPerSecond }
    }
}

/// Which stored file plays for a cloud video.
enum VideoPlayback {
    /// The fast version (`sp`), or what the user sees in Photos: the edit when there is one, else the original.
    static func role(_ quality: VideoQuality, for item: MediaItem) -> String {
        if quality == .streamingCopy, item.hasStreamingCopy { return "sp" }
        return item.hasEdit == true && !item.parts("e").isEmpty ? "e" : "o"
    }

    static func initialQuality(for item: MediaItem) -> VideoQuality {
        VideoQualityPolicy.initial(preference: Prefs.videoQuality, hasCopy: item.hasStreamingCopy,
                                   isExpensiveNetwork: NetworkStatus.shared.isExpensive,
                                   bytesPerSecond: StreamingThroughput.shared.bytesPerSecond,
                                   originalBitsPerSecond: item.originalBitsPerSecond)
    }
}
