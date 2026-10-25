import SwiftUI
import AVFoundation
import MemvoCore

/// One cloud video in a viewer: its player, which version plays (original or fast version) and switching between
/// them at the same moment. With Automatic quality, a stall of a few seconds on the original switches to the fast
/// version.
@MainActor
final class CloudVideoSession: ObservableObject {
    @Published private(set) var item: MediaItem
    let player: AVPlayer
    @Published private(set) var quality: VideoQuality
    @Published private(set) var switching = false
    /// "Make Fast Version" is running, or just failed (shown briefly in the pill).
    @Published private(set) var making = false
    @Published private(set) var makeFailed = false
    /// Keeps the resource loader alive while its item plays.
    private var stream: StreamingAsset?
    private let reader: MediaReader
    /// The user picked a quality in the viewer: never switch on our own after that.
    private(set) var userChose: Bool
    private var stallTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var statusObservation: NSKeyValueObservation?
    private let opened = Date()
    private var playingLogged = false

    var hasCopy: Bool { item.hasStreamingCopy }

    /// `chosen`: the user's earlier pick for this item in the same viewer, if any.
    init(item: MediaItem, reader: MediaReader, chosen: VideoQuality? = nil) {
        self.item = item
        self.reader = reader
        let quality = chosen ?? VideoPlayback.initialQuality(for: item)
        self.quality = quality
        userChose = chosen != nil
        let (first, stream) = Self.playerItem(item, quality, reader)
        self.stream = stream
        player = AVPlayer(playerItem: first)
        if item.hasStreamingCopy { appLog("Video quality: \(item.filename) opens \(Self.name(quality))") }
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.timeControlChanged() }
        }
    }

    static func name(_ q: VideoQuality) -> String { q == .original ? "the original" : "the fast version" }

    private static func playerItem(_ item: MediaItem, _ quality: VideoQuality, _ reader: MediaReader) -> (AVPlayerItem, StreamingAsset?) {
        // App Review demo: the bundled clip stands in for both versions.
        if let demo = DemoMode.fileURL(for: item) { return (AVPlayerItem(url: demo), nil) }
        let stream = StreamingAsset(item: item, role: VideoPlayback.role(quality, for: item), reader: reader)
        return (AVPlayerItem(asset: stream.asset), stream)
    }

    /// From the viewer's quality menu.
    func choose(_ q: VideoQuality) {
        userChose = true
        Task { await switchTo(q) }
    }

    /// "Make Fast Version" for a video without one (backed up before fast versions, and not on this device).
    func makeFastVersion() {
        guard !making, !hasCopy else { return }
        making = true
        makeFailed = false
        let id = item.id
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try await AppEnvironment.shared.engine.makeFastVersion(itemId: id) }.value
                if let updated = try? AppEnvironment.shared.store.item(id: id) { item = updated }
                making = false
                // The user waited for it: use it now if it's the better fit for this connection.
                if !userChose, VideoPlayback.initialQuality(for: item) == .streamingCopy { await switchTo(.streamingCopy) }
            } catch {
                AppLog.shared.warn("Make fast version of \(item.filename) failed: \(error.localizedDescription)")
                making = false
                makeFailed = true
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                makeFailed = false
            }
        }
    }

    /// Leaving the video: stop playing and let go of its stream, which also stops its download.
    func stop() {
        if let speed = StreamingThroughput.shared.bytesPerSecond, stream != nil {
            appLog("Video speed: Telegram delivered about \(Format.bytes(Int64(speed)))/s while \(item.filename) played")
        }
        stallTask?.cancel()
        startTask?.cancel()
        player.pause()
        stream?.cancel()
        player.replaceCurrentItem(with: nil)
        stream = nil
    }

    private func switchTo(_ q: VideoQuality) async {
        guard q != quality, !switching, q == .original || hasCopy else { return }
        switching = true
        defer { switching = false }
        stallTask?.cancel()
        let time = player.currentTime()
        let wasPlaying = player.timeControlStatus != .paused
        let (nextItem, next) = Self.playerItem(item, q, reader)
        player.replaceCurrentItem(with: nextItem)
        stream = next
        quality = q
        appLog("Video quality: \(item.filename) switched to \(Self.name(q)) at \(String(format: "%.1f", time.seconds)) s")
        // Seek once the new item can take it, so the video continues where it was.
        await Self.waitUntilLoaded(nextItem, timeout: 20)
        guard nextItem.status == .readyToPlay, player.currentItem === nextItem else { return }
        if time.isNumeric, time.seconds > 0 { await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) }
        if wasPlaying { player.play() }
    }

    /// Waits until the item is ready or failed (or the timeout passes), checking a few times a second.
    private static func waitUntilLoaded(_ item: AVPlayerItem, timeout: TimeInterval) async {
        let end = Date().addingTimeInterval(timeout)
        while item.status == .unknown, Date() < end, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Once half a second is buffered, start instead of waiting for AVPlayer's larger "won't stall" buffer: measured
    /// speeds deliver the fast version two to four times faster than it plays, so it keeps ahead. Stalls later are still handled by AVPlayer.
    private func startSoon() {
        guard startTask == nil else { return }
        startTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                let reason = self.player.reasonForWaitingToPlay
                if reason == .toMinimizeStalls || reason == .evaluatingBufferingRate, let item = self.player.currentItem,
                   item.bufferedAhead >= 0.5 {
                    self.player.playImmediately(atRate: self.player.defaultRate > 0 ? self.player.defaultRate : 1)
                    break
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            self?.startTask = nil
        }
    }

    private func timeControlChanged() {
        if player.timeControlStatus == .playing, !playingLogged {
            playingLogged = true
            appLog(String(format: "Video timing: %@: playing after %.2f s", item.filename, Date().timeIntervalSince(opened)))
        }
        if player.timeControlStatus == .waitingToPlayAtSpecifiedRate { startSoon() }
        stallTask?.cancel()
        guard player.timeControlStatus == .waitingToPlayAtSpecifiedRate, !switching,
              VideoQualityPolicy.fallsBackOnStall(playing: quality, preference: Prefs.videoQuality, hasCopy: hasCopy, userChose: userChose)
        else { return }
        stallTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(VideoQualityPolicy.stallSecondsBeforeFallback * 1_000_000_000))
            guard let self, !Task.isCancelled, self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
            appLog("Video quality: \(self.item.filename) stalled for \(Int(VideoQualityPolicy.stallSecondsBeforeFallback)) s on the original")
            await self.switchTo(.streamingCopy)
        }
    }
}

/// The quality pill on cloud videos: says what plays and switches to the other version at any time. Videos
/// without a fast version offer to make one.
struct VideoQualityMenu: View {
    @ObservedObject var session: CloudVideoSession

    /// "4K" / "1080p" when the two versions differ in resolution; otherwise "Original" / "Fast".
    private func label(_ q: VideoQuality) -> String? {
        let item = session.item
        guard let mine = item.resolutionLabel(q), mine != item.resolutionLabel(q == .original ? .streamingCopy : .original) else { return nil }
        return mine
    }

    private var title: String {
        if session.making { return "Preparing" }
        if session.makeFailed { return "Couldn't Prepare" }
        return label(session.quality) ?? (session.quality == .original ? "Original" : "Fast")
    }

    private func named(_ title: String, _ q: VideoQuality) -> String {
        label(q).map { "\(title) (\($0))" } ?? title
    }

    var body: some View {
        Menu {
            if session.hasCopy {
                Section("Video Quality") {
                    option(.original, named("Play Original Quality", .original))
                    option(.streamingCopy, named("Play Fast Version", .streamingCopy))
                }
            } else {
                Section("This video has no fast version yet") {
                    Button { session.makeFastVersion() } label: {
                        Label(session.making ? "Making Fast Version…" : "Make Fast Version", systemImage: "bolt")
                    }
                    .disabled(session.making)
                }
            }
        } label: {
            HStack(spacing: 5) {
                if session.switching || session.making { ProgressView().controlSize(.small).tint(.white) }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(.ultraThinMaterial, in: Capsule())
            .environment(\.colorScheme, .dark)
            .contentShape(Capsule())
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Video quality")
        .accessibilityValue(session.making ? "Preparing fast version" : (session.quality == .original ? "Original" : "Fast version"))
    }

    @ViewBuilder private func option(_ q: VideoQuality, _ title: String) -> some View {
        Button { session.choose(q) } label: {
            if session.quality == q { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}

/// The cloud video sessions of one viewer, so its top bar can show the quality of the video on screen. The
/// user's pick is remembered for the viewer's lifetime, even when a page is recreated.
@MainActor
final class ViewerVideoSessions: ObservableObject {
    @Published private(set) var sessions: [String: CloudVideoSession] = [:]
    private var chosen: [String: VideoQuality] = [:]

    func open(_ entryId: String, item: MediaItem, reader: MediaReader) -> CloudVideoSession {
        if let existing = sessions[entryId], existing.item.id == item.id { return existing }
        let session = CloudVideoSession(item: item, reader: reader, chosen: chosen[item.id])
        sessions[entryId] = session
        return session
    }

    func close(_ entryId: String) {
        guard let session = sessions.removeValue(forKey: entryId) else { return }
        if session.userChose { chosen[session.item.id] = session.quality }
        session.stop()
    }

    /// The viewer closed: no player may keep downloading in the background.
    func closeAll() {
        for id in Array(sessions.keys) { close(id) }
    }
}

/// Fetches the start of the neighbouring cloud videos, but only once the video on screen has plenty buffered, so
/// they never take its bandwidth. Moving on cancels the previous fetches and their downloads.
@MainActor
final class NeighbourPrefetcher {
    private var task: Task<Void, Never>?

    func schedule(_ items: [MediaItem], whenReady currentIsReady: @escaping @MainActor () -> Bool) {
        task?.cancel()
        guard !items.isEmpty else { return }
        task = Task {
            let deadline = Date().addingTimeInterval(20)
            while !currentIsReady(), Date() < deadline {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
            }
            for item in items {
                if Task.isCancelled { return }
                let role = VideoPlayback.role(VideoPlayback.initialQuality(for: item), for: item)
                // A fast version starts from its first ~0.5 MB (index first); an original needs more, plus its tail.
                await AppEnvironment.shared.reader.prefetch(item, role: role, bytes: role == "sp" ? 512 << 10 : 2 << 20)
            }
        }
    }

    func cancel() { task?.cancel() }
}

extension AVPlayerItem {
    /// Seconds loaded ahead of the playhead.
    var bufferedAhead: Double {
        let now = currentTime()
        for range in loadedTimeRanges.map(\.timeRangeValue) where range.containsTime(now) {
            return (range.end - now).seconds
        }
        return 0
    }

    /// Enough of this video is loaded that fetching others won't make it stall: 15 s ahead, or up to its end.
    var hasPlentyBuffered: Bool {
        guard status == .readyToPlay else { return false }
        let now = currentTime()
        for range in loadedTimeRanges.map(\.timeRangeValue) where range.containsTime(now) || range.start > now {
            let end = range.end
            if (end - now).seconds >= 15 { return true }
            if duration.isNumeric, (duration - end).seconds < 0.5 { return true }
        }
        return false
    }
}

/// Spinner over a video while it switches quality (the new version is loading at the same moment).
struct VideoSwitchingOverlay: View {
    @ObservedObject var session: CloudVideoSession

    var body: some View {
        if session.switching {
            ProgressView().tint(.white).padding(14).background(.black.opacity(0.35), in: Circle())
                .allowsHitTesting(false)
        }
    }
}

/// When the grid comes to rest, fetches the start of the fast versions of the cloud videos on screen, so tapping one
/// starts at once (like Photos and Google Photos). Wi-Fi only, at most a screenful, one at a time; scrolling on or
/// opening a video cancels it, so it never competes with what's being watched.
@MainActor
final class VisibleVideoPreloader {
    static let shared = VisibleVideoPreloader()
    /// Enough for a fast version to start: its index and first seconds.
    static let bytes: Int64 = 512 << 10
    private var task: Task<Void, Never>?

    func gridSettled(on entries: [GalleryEntry]) {
        task?.cancel()
        let items = entries.compactMap { e -> MediaItem? in
            // No memory of what was preloaded: the cache can be cleared or trimmed at any time, and fetching a start
            // that's already downloaded returns at once.
            guard e.isCloudOnly, let item = e.item, item.kind == .video, item.hasStreamingCopy, item.isViewableFromCloud else { return nil }
            return item
        }.prefix(6)
        guard !items.isEmpty, !NetworkStatus.shared.isExpensive, !DemoMode.isActive else { return }
        task = Task {
            // Let a fling settle completely before using the network.
            try? await Task.sleep(nanoseconds: 400_000_000)
            let started = Date()
            var done = 0
            for item in items {
                if Task.isCancelled { break }
                await AppEnvironment.shared.reader.prefetch(item, role: "sp", bytes: Self.bytes)
                if !Task.isCancelled { done += 1 }
            }
            if done > 0 { appLog(String(format: "Preloaded the start of %d cloud videos on screen in %.1f s", done, Date().timeIntervalSince(started))) }
        }
    }

    func cancel() { task?.cancel() }
}
