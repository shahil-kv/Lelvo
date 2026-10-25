import SwiftUI
import AVFoundation
import MemvoCore

/// One cloud video in a viewer: its player, which version plays (original or 1080p copy) and switching between
/// them at the same moment. With Automatic quality, a stall of a few seconds on the original switches to the copy.
@MainActor
final class CloudVideoSession: ObservableObject {
    let item: MediaItem
    let player: AVPlayer
    @Published private(set) var quality: VideoQuality
    @Published private(set) var switching = false
    /// Keeps the resource loader alive while its item plays.
    private var stream: StreamingAsset?
    private let reader: MediaReader
    /// The user picked a quality in the viewer: never switch on our own after that.
    private(set) var userChose: Bool
    private var stallTask: Task<Void, Never>?
    private var statusObservation: NSKeyValueObservation?

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

    static func name(_ q: VideoQuality) -> String { q == .original ? "the original" : "the 1080p copy" }

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

    private func timeControlChanged() {
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

/// The quality pill in the viewer, shown for cloud videos that have a 1080p copy: says what plays and lets the
/// user switch to the other version at any time.
struct VideoQualityMenu: View {
    @ObservedObject var session: CloudVideoSession

    var body: some View {
        Menu {
            Section("Video Quality") {
                option(.original, "Play Original Quality")
                option(.streamingCopy, "Play 1080p Copy")
            }
        } label: {
            HStack(spacing: 5) {
                if session.switching { ProgressView().controlSize(.small).tint(.white) }
                Text(session.quality == .original ? "Original" : "1080p")
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
        .accessibilityValue(session.quality == .original ? "Original" : "1080p copy")
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
        session.player.pause()
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
