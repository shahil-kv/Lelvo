import SwiftUI
import AVFoundation
import LelvoCore

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
    /// The fast version shows the wrong picture (turned, stretched): the original plays and the menu offers a remake.
    @Published private(set) var fastBroken = false
    private var shapeTask: Task<Void, Never>?
    /// Keeps the resource loader alive while its item plays.
    private var stream: StreamingAsset?
    private let reader: MediaReader
    /// The user picked a quality in the viewer: never switch on our own after that.
    private(set) var userChose: Bool
    private var stallTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var statusObservation: NSKeyValueObservation?
    private var watchdog: Task<Void, Never>?
    private let opened = Date()
    private var playingLogged = false
    /// The viewer is closing or closed: nothing here may start the player again (a quality switch, the early start).
    private var held = false

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
        fastBroken = VideoPlayback.isBrokenFastVersion(item)
        watchStart()
        verifyShape(of: first)
    }

    /// Checks that the fast version's picture has the original's shape once its size is known; if not, plays the
    /// original. Older builds wrote some fast versions on a wrong frame size, which showed turned and stretched.
    private func verifyShape(of playerItem: AVPlayerItem) {
        shapeTask?.cancel()
        guard quality == .streamingCopy, stream != nil, item.hasEdit != true else { return }
        shapeTask = Task { [weak self] in
            for _ in 0..<150 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, !Task.isCancelled, self.player.currentItem === playerItem else { return }
                let size = playerItem.presentationSize
                guard size.width > 0, size.height > 0 else { continue }
                let item = self.item
                if !VideoQualityPolicy.fastVersionMatches(originalWidth: item.pixelWidth, originalHeight: item.pixelHeight,
                                                          copyWidth: Int(size.width.rounded()), copyHeight: Int(size.height.rounded())) {
                    appLog("Video quality: the fast version of \(item.filename) is \(Int(size.width))x\(Int(size.height)) for a \(item.pixelWidth)x\(item.pixelHeight) video, playing the original")
                    VideoPlayback.markFastVersion(item, broken: true)
                    self.fastBroken = true
                    await self.switchTo(.original)
                }
                return
            }
        }
    }

    /// A video that shows its first frame and then never plays left no trace in the log: no download was waiting, so
    /// nothing else wrote a line. Says what the player is waiting for, 5 and 20 s after opening, until it plays.
    private func watchStart() {
        watchdog = Task { [weak self] in
            for delay in [5.0, 15.0] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, !Task.isCancelled, !self.playingLogged else { return }
                let p = self.player
                let status: String
                switch p.timeControlStatus {
                case .paused: status = "paused"
                case .waitingToPlayAtSpecifiedRate: status = "waiting (\(p.reasonForWaitingToPlay?.rawValue ?? "no reason"))"
                case .playing: status = "playing"
                @unknown default: status = "unknown"
                }
                let itemStatus = p.currentItem.map { ["unknown", "ready", "failed"][min($0.status.rawValue, 2)] } ?? "no item"
                AppLog.shared.warn(String(format: "Video not playing after %.0f s: %@ [%@]: player %@, item %@, %.1f s buffered, %@",
                                          Date().timeIntervalSince(self.opened), self.item.filename, VideoPlayback.role(self.quality, for: self.item),
                                          status, itemStatus, p.currentItem?.bufferedAhead ?? 0, self.stream?.pendingSummary ?? "no stream"))
            }
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
    /// `remake`: replaces a fast version that plays wrong (the original is untouched).
    func makeFastVersion(remake: Bool = false) {
        guard !making, remake || !hasCopy else { return }
        making = true
        makeFailed = false
        let id = item.id
        Task {
            // The old fast version is deleted from Telegram first: keep playing from the original meanwhile, and come
            // back to the new one when it is ready. Playing the old one (or opening it) would stall for good.
            let wasFast = remake && quality == .streamingCopy
            if wasFast { await switchTo(.original, whileMaking: true) }
            do {
                try await Task.detached(priority: .userInitiated) { try await AppEnvironment.shared.engine.makeFastVersion(itemId: id, remake: remake) }.value
                if let updated = try? AppEnvironment.shared.store.item(id: id) { item = updated }
                making = false
                if remake { VideoPlayback.markFastVersion(item, broken: false); fastBroken = false }
                if wasFast { await switchTo(.streamingCopy) }
                // The user waited for it: use it now if it's the better fit for this connection.
                if !remake, !userChose, VideoPlayback.initialQuality(for: item) == .streamingCopy { await switchTo(.streamingCopy) }
            } catch {
                AppLog.shared.warn("Make fast version of \(item.filename) failed: \(error.localizedDescription)")
                if let updated = try? AppEnvironment.shared.store.item(id: id) { item = updated }
                making = false
                makeFailed = true
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                makeFailed = false
            }
        }
    }

    /// Leaving the video: stop playing and let go of its stream, which also stops its download.
    func stop() {
        if !playingLogged {
            appLog(String(format: "Video closed before it played: %@ after %.1f s", item.filename, Date().timeIntervalSince(opened)))
        }
        if let speed = StreamingThroughput.shared.bytesPerSecond, stream != nil {
            appLog("Video speed: Telegram delivered about \(Format.bytes(Int64(speed)))/s while \(item.filename) played")
        }
        held = true
        stallTask?.cancel()
        startTask?.cancel()
        watchdog?.cancel()
        shapeTask?.cancel()
        player.pause()
        stream?.cancel()
        player.replaceCurrentItem(with: nil)
        stream = nil
    }

    /// The viewer started closing: stop now, and stay stopped unless the close is cancelled.
    func hold() {
        held = true
        player.pause()
    }

    func release() { held = false }

    private func switchTo(_ q: VideoQuality, whileMaking: Bool = false) async {
        // While a fast version is being remade the old one no longer exists in Telegram.
        guard q != quality, !switching, q == .original || (hasCopy && (!making || whileMaking)) else {
            appLog("Video quality: \(item.filename) switch to \(Self.name(q)) ignored (now \(Self.name(quality)), switching \(switching), remaking \(making), fast version \(hasCopy ? "yes" : "no"))")
            return
        }
        switching = true
        defer { switching = false }
        stallTask?.cancel()
        let time = player.currentTime()
        let wasPlaying = player.timeControlStatus != .paused
        let (nextItem, next) = Self.playerItem(item, q, reader)
        // The start time goes on the item before it is attached: AVPlayer then asks for the data around that moment
        // instead of loading the start of the file first (a 4K original's index can sit at the end) and seeking after.
        // Waiting for "ready" and giving up after 20 s left the video stuck mid-way and the quality menu blocked.
        if time.isNumeric, time.seconds > 0 {
            await nextItem.seek(to: time, toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600))
        }
        player.replaceCurrentItem(with: nextItem)
        stream = next
        quality = q
        appLog("Video quality: \(item.filename) switched to \(Self.name(q)) at \(String(format: "%.1f", time.seconds)) s")
        if wasPlaying, !held { player.play() }
        verifyShape(of: nextItem)
    }

    /// Once half a second is buffered, start instead of waiting for AVPlayer's larger "won't stall" buffer: measured
    /// speeds deliver the fast version two to four times faster than it plays, so it keeps ahead. Stalls later are still handled by AVPlayer.
    private func startSoon() {
        guard startTask == nil else { return }
        startTask = Task { [weak self] in
            while let self, !Task.isCancelled, !self.held, self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
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
        // A viewer that is closing must stay silent whatever restarts the player (a load finishing, a stall ending).
        if held, player.timeControlStatus != .paused {
            player.pause()
            return
        }
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

    private var title: String {
        if session.making { return session.fastBroken ? "Repairing" : "Preparing" }
        if session.makeFailed { return "Couldn't Prepare" }
        return session.quality == .original ? "Original" : "Fast"
    }

    var body: some View {
        Menu {
            if session.hasCopy {
                // A system picker: the checkmark column is the same width for every row, so choosing a row never shifts
                // or wraps the others. Short names keep each on one line.
                Section("Video Quality") {
                    Picker("Video Quality", selection: Binding(get: { session.quality }, set: { session.choose($0) })) {
                        Text("Original").tag(VideoQuality.original)
                        Text("Fast").tag(VideoQuality.streamingCopy)
                            .disabled(session.making || session.fastBroken)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                // Only when the fast version was found to play wrong: a rebuild is not a quality a viewer should pick.
                if session.fastBroken {
                    Section("The fast version of this video doesn't play right") {
                        Button { session.makeFastVersion(remake: true) } label: {
                            Label(session.making ? "Repairing…" : "Repair Fast Version", systemImage: "wrench.and.screwdriver")
                        }
                        .disabled(session.making)
                    }
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
}

/// The cloud video sessions of one viewer, so its top bar can show the quality of the video on screen. The
/// user's pick is remembered for the viewer's lifetime, even when a page is recreated.
@MainActor
final class ViewerVideoSessions: ObservableObject {
    @Published private(set) var sessions: [String: CloudVideoSession] = [:]
    private var chosen: [String: VideoQuality] = [:]
    /// Phone videos in this viewer (cloud ones are in `sessions`), so a close can stop every player it made.
    private let localPlayers = NSHashTable<AVPlayer>.weakObjects()
    /// The close went through. A video that finishes loading during the close animation must not start: it played on
    /// with nothing on screen to stop it.
    private(set) var closing = false

    deinit { appLog("Viewer freed") }

    /// A phone video's player. One that arrives while the viewer closes is stopped at once.
    func register(_ player: AVPlayer) {
        localPlayers.add(player)
        if closing { player.pause() }
    }

    /// `how`: what started the close (✕, a swipe down, the screen going away), for the log.
    func beginClose(_ how: String) {
        guard !closing else { return }
        closing = true
        let players = sessions.values.map(\.player) + localPlayers.allObjects
        appLog("Viewer closing (\(how)): pausing \(players.filter { $0.rate != 0 }.count) of \(players.count) video players")
        sessions.values.forEach { $0.hold() }
        localPlayers.allObjects.forEach { $0.pause() }
        // Once the close animation is over nothing may still play. A warning here means a path was missed.
        let watched = NSHashTable<AVPlayer>.weakObjects()
        players.forEach(watched.add)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if let self, !self.closing { return }
            let playing = watched.allObjects.filter { $0.rate != 0 }
            playing.forEach { $0.pause() }
            if playing.isEmpty { appLog("Viewer closed: \(players.count) video players stopped") }
            else {
                let state = playing.map { p in "\(p.timeControlStatus.rawValue), \(p.reasonForWaitingToPlay?.rawValue ?? "no reason")" }.joined(separator: "; ")
                AppLog.shared.warn("Viewer closed but \(playing.count) video players still played; stopped them [\(state)]")
            }
        }
    }

    /// A swipe down that was let go: the viewer stays.
    func cancelClose() {
        guard closing else { return }
        appLog("Viewer close cancelled")
        closing = false
        sessions.values.forEach { $0.release() }
    }

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

/// Fetches the neighbouring cloud items ahead of a swipe (a video's start, a photo's original), but only once a video
/// on screen has plenty buffered, so they never take its bandwidth. Moving on cancels the previous fetches.
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
                if item.kind != .video {
                    await AppEnvironment.shared.media.prefetchPhoto(item)
                    continue
                }
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

extension AVPlayer {
    /// Loaded end / duration when both are known; otherwise nil (indeterminate ring).
    var bufferProgress: Double? {
        guard let item = currentItem else { return nil }
        let d = item.duration.seconds
        guard d.isFinite, d > 0 else { return nil }
        let end = item.loadedTimeRanges.map(\.timeRangeValue.end.seconds).filter(\.isFinite).max() ?? 0
        guard end > 0 else { return nil }
        return min(1, max(0, end / d))
    }
}

/// Thin ring over a video while it buffers or switches quality (preview: download ring).
struct VideoDownloadRing: View {
    /// 0…1 when known; nil spins quietly.
    var progress: Double?
    var body: some View {
        ZStack {
            if let progress, progress.isFinite {
                Circle()
                    .stroke(Color.white.opacity(0.18), lineWidth: 3)
                    .frame(width: 44, height: 44)
                Circle()
                    .trim(from: 0, to: min(1, max(0, progress)))
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 44, height: 44)
                Text("\(Int((min(1, max(0, progress)) * 100).rounded()))%")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            } else {
                ProgressView().tint(.white)
            }
        }
        .padding(14)
        .background(.black.opacity(0.35), in: Circle())
        .allowsHitTesting(false)
        .accessibilityLabel(progress.map { "Loading \(Int(($0 * 100).rounded())) percent" } ?? "Loading")
    }
}

/// What a video's ring shows: how much of it has loaded, and whether the player is waiting for data. It watches the
/// player and its item (`loadedTimeRanges` changes while the player is stalled, where a clock tick would not come).
@MainActor
final class VideoLoadProgress: ObservableObject {
    @Published private(set) var progress: Double?
    @Published private(set) var isWaiting = false
    private var observations: [NSKeyValueObservation] = []
    private var itemObservations: [NSKeyValueObservation] = []

    func attach(_ player: AVPlayer) {
        detach()
        refresh(player)
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self, weak player] _, _ in
            Task { @MainActor in if let player { self?.refresh(player) } }
        })
        observations.append(player.observe(\.currentItem, options: [.new]) { [weak self, weak player] _, _ in
            Task { @MainActor in if let player { self?.observeItem(of: player) } }
        })
        observeItem(of: player)
    }

    func detach() {
        observations = []
        itemObservations = []
    }

    private func observeItem(of player: AVPlayer) {
        itemObservations = []
        refresh(player)
        guard let item = player.currentItem else { return }
        itemObservations.append(item.observe(\.loadedTimeRanges, options: [.new]) { [weak self, weak player] _, _ in
            Task { @MainActor in if let player { self?.refresh(player) } }
        })
        itemObservations.append(item.observe(\.duration, options: [.new]) { [weak self, weak player] _, _ in
            Task { @MainActor in if let player { self?.refresh(player) } }
        })
    }

    private func refresh(_ player: AVPlayer) {
        let value = player.bufferProgress
        if progress != value { progress = value }
        let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        if isWaiting != waiting { isWaiting = waiting }
    }
}

/// The ring for a player: a percentage once the length is known, otherwise a quiet spinner. With `onlyWhileWaiting` it
/// shows only while the player is stalled (after the first frame), otherwise always (before the first frame).
struct VideoLoadingRing: View {
    let player: AVPlayer
    var onlyWhileWaiting = false
    @StateObject private var model = VideoLoadProgress()

    var body: some View {
        Group {
            if !onlyWhileWaiting || model.isWaiting {
                VideoDownloadRing(progress: model.progress)
            }
        }
        .onAppear { model.attach(player) }
        .onDisappear { model.detach() }
    }
}

/// Ring over a video while it switches quality (the new version is loading at the same moment).
struct VideoSwitchingOverlay: View {
    @ObservedObject var session: CloudVideoSession

    var body: some View {
        if session.switching {
            VideoDownloadRing(progress: nil)
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
    /// The last screenful handled: the grid refreshes every second or two during a backup, which re-triggers this.
    private var lastIds: [String] = []
    private var lastAt = Date.distantPast

    func gridSettled(on entries: [GalleryEntry]) {
        let ids = entries.map(\.id)
        if ids == lastIds, Date().timeIntervalSince(lastAt) < 60, task != nil { return }
        lastIds = ids
        lastAt = Date()
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
            // Right after launch the grid settles a second or two before Telegram is ready, and every read failed.
            // Wait for it here; the grid and thumbnails never wait for this.
            guard (try? await AppEnvironment.shared.td.waitUntilReady(timeout: 15)) != nil, !Task.isCancelled else {
                if !Task.isCancelled { lastIds = [] }
                return
            }
            let started = Date()
            var done = 0
            for item in items {
                if Task.isCancelled { break }
                if await AppEnvironment.shared.reader.prefetch(item, role: "sp", bytes: Self.bytes) { done += 1 }
            }
            // Nothing fetched (offline, a read failed): let the next time the grid settles try again instead of
            // treating this screenful as done for a minute.
            if done == 0, !Task.isCancelled { lastIds = [] }
            let took = Date().timeIntervalSince(started)
            // Already on the device returns at once; only real downloads are worth a log line.
            if done > 0, took > 0.2 { appLog(String(format: "Preloaded the start of %d cloud videos on screen in %.1f s", done, took)) }
        }
    }

    func cancel() { task?.cancel() }
}
