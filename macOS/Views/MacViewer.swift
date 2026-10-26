import SwiftUI
import AVKit
import Photos
import PhotosUI
import MemvoCore

/// Where a tile is on screen and what it shows, so the viewer can zoom out of it and back into it.
@MainActor
final class TileRegistry {
    static let shared = TileRegistry()
    /// Set by the grid: a tile's rect in window (SwiftUI global) coordinates, nil when it's off screen.
    var frameProvider: ((String) -> CGRect?)?

    func frame(for id: String) -> CGRect? { frameProvider?(id) }
    func image(for entry: GalleryEntry) -> PlatformImage? { ThumbnailPipeline.shared.cached(entry)?.image }
}

/// Decoded full-size images of the items around the one on screen, so ← → shows them instantly.
@MainActor
final class ViewerImageCache {
    static let shared = ViewerImageCache()
    private let cache = NSCache<NSString, PlatformImage>()
    private var loading = Set<String>()

    init() { cache.countLimit = 12 }

    func image(for id: String) -> PlatformImage? { cache.object(forKey: id as NSString) }
    func store(_ image: PlatformImage, for id: String) { cache.setObject(image, forKey: id as NSString) }

    /// Local photos and cloud photos whose original is already cached (never starts big downloads).
    func preload(_ entry: GalleryEntry, target: CGSize) {
        guard image(for: entry.id) == nil, !entry.isVideo, !entry.isLive, !loading.contains(entry.id) else { return }
        loading.insert(entry.id)
        Task {
            defer { loading.remove(entry.id) }
            let env = AppEnvironment.shared
            var img: PlatformImage?
            if let asset = entry.asset {
                img = await env.photos.image(for: asset, targetSize: target)
            } else if let item = entry.item, item.kind == .photo, item.isViewableFromCloud {
                // Not downloaded yet: fetch it ahead of the arrow key (Wi-Fi, not huge files).
                await env.media.prefetchPhoto(item)
                let role = item.hasEdit == true && !item.parts("e").isEmpty ? "e" : "o"
                if let url = env.originalsCache.url(for: CloudMediaService.originalKey(item, role: role)) {
                    img = await MacViewerPage.decode(url, maxPixel: max(target.width, target.height))
                }
            }
            if let img { store(img, for: entry.id) }
        }
    }
}

/// Full-window viewer: zooms out of the tile, ← → or a two-finger swipe between items, pinch / double-click
/// to zoom, Space to play, Esc to zoom back into the grid. Cloud videos stream from Telegram.
struct MacViewer: View {
    let entries: [GalleryEntry]
    @Binding var currentId: String?
    let onClose: () -> Void

    @State private var zoomed = false
    @State private var hoverEdge: HorizontalEdge?
    @State private var forward = true
    @State private var hero: Hero?
    @State private var expanded = false
    @State private var contentVisible = false
    @State private var closing = false
    @State private var swipeMonitor: Any?
    @State private var swipeAccumulated: CGFloat = 0
    @State private var swipeConsumed = false
    @State private var viewerWidth: CGFloat = 0
    @StateObject private var videos = ViewerVideoSessions()
    @State private var prefetcher = NeighbourPrefetcher()
    @FocusState private var focused: Bool

    struct Hero {
        let image: PlatformImage
        let source: CGRect
        let aspect: CGFloat
    }

    private var index: Int? { currentId.flatMap { id in entries.firstIndex { $0.id == id } } }
    private var current: GalleryEntry? { index.map { entries[$0] } }

    var body: some View {
        GeometryReader { geo in
            let bounds = CGRect(origin: .zero, size: geo.size)
            ZStack {
                Color.black.opacity(expanded ? 1 : 0)
                if let current {
                    MacViewerPage(entry: current, isCurrent: true, zoomed: $zoomed)
                        .environmentObject(videos)
                        .id(current.id)
                        .transition(.asymmetric(
                            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
                        .opacity(contentVisible ? 1 : 0)
                }
                if let hero, !contentVisible {
                    let target = expanded ? Self.fit(aspect: hero.aspect, in: bounds) : hero.source
                    Image(platformImage: hero.image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: target.width, height: target.height)
                        .clipShape(RoundedRectangle(cornerRadius: expanded ? 0 : 3, style: .continuous))
                        .position(x: target.midX, y: target.midY)
                        .allowsHitTesting(false)
                }
            }
            .clipped()
            .onAppear { open(in: geo.frame(in: .global)) }
            .onChange(of: geo.size.width, initial: true) { _, w in viewerWidth = w }
        }
        .overlay(alignment: .leading) {
            if contentVisible, hoverEdge == .leading, let i = index, i > 0 { edgeButton("chevron.left") { step(-1) } }
        }
        .overlay(alignment: .trailing) {
            if contentVisible, hoverEdge == .trailing, let i = index, i < entries.count - 1 { edgeButton("chevron.right") { step(1) } }
        }
        // Tracked on the whole viewer, arrows included: the arrow stays while the pointer is on it.
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                let edge: HorizontalEdge? = p.x < 140 ? .leading : (p.x > viewerWidth - 140 ? .trailing : nil)
                if edge != hoverEdge { withAnimation(.easeOut(duration: 0.15)) { hoverEdge = edge } }
            case .ended:
                withAnimation(.easeOut(duration: 0.2)) { hoverEdge = nil }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .onKeyPress(.space) {
            if current?.isVideo == true {
                NotificationCenter.default.post(name: .macViewerTogglePlay, object: currentId)
            } else {
                close()
            }
            return .handled
        }
        .onReceive(NotificationCenter.default.publisher(for: .macViewerClose)) { _ in close() }
        .onChange(of: currentId) { _, _ in prefetchNeighbours() }
        .onAppear {
            focused = true
            installSwipeMonitor()
        }
        .onDisappear {
            removeSwipeMonitor()
            videos.closeAll()
        }
    }

    // MARK: - Open / close

    /// Hero zoom from the tile (like Photos), then the real page fades in underneath.
    private func open(in container: CGRect) {
        VisibleVideoPreloader.shared.cancel()
        // Start fetching a cloud video during the zoom animation instead of after it.
        if let entry = current, entry.isCloudOnly, let item = entry.item, item.kind == .video, item.isViewableFromCloud {
            let role = VideoPlayback.role(VideoPlayback.initialQuality(for: item), for: item)
            Task { await AppEnvironment.shared.reader.prefetch(item, role: role, bytes: role == "sp" ? VisibleVideoPreloader.bytes : 2 << 20) }
        }
        prefetchNeighbours()
        guard let entry = current, let source = TileRegistry.shared.frame(for: entry.id),
              let image = TileRegistry.shared.image(for: entry) else {
            withAnimation(.easeOut(duration: 0.2)) { expanded = true; contentVisible = true }
            return
        }
        heroOrigin = CGPoint(x: -container.minX, y: -container.minY)
        hero = Hero(image: image, source: source.offsetBy(dx: heroOrigin.x, dy: heroOrigin.y), aspect: Self.aspect(of: entry, image: image))
        withAnimation(.spring(duration: 0.36, bounce: 0.08)) {
            expanded = true
        } completion: {
            withAnimation(.easeOut(duration: 0.12)) { contentVisible = true }
        }
    }

    private func close() {
        guard !closing else { return }
        closing = true
        removeSwipeMonitor()
        guard let entry = current, !zoomed, let source = TileRegistry.shared.frame(for: entry.id),
              let image = TileRegistry.shared.image(for: entry) else {
            withAnimation(.easeIn(duration: 0.16)) { expanded = false; contentVisible = false } completion: { onClose() }
            return
        }
        // Zoom back into the tile of the item on screen (it may differ from the one that was opened).
        hero = Hero(image: ViewerImageCache.shared.image(for: entry.id) ?? image,
                    source: source.offsetBy(dx: heroOrigin.x, dy: heroOrigin.y),
                    aspect: Self.aspect(of: entry, image: image))
        contentVisible = false
        withAnimation(.spring(duration: 0.32, bounce: 0)) {
            expanded = false
        } completion: {
            onClose()
        }
    }

    /// The container origin in gallery coordinates, captured on open (tile frames are in gallery space).
    @State private var heroOrigin: CGPoint = .zero

    static func aspect(of entry: GalleryEntry, image: PlatformImage) -> CGFloat {
        let w = CGFloat(entry.asset?.pixelWidth ?? entry.item?.pixelWidth ?? 0)
        let h = CGFloat(entry.asset?.pixelHeight ?? entry.item?.pixelHeight ?? 0)
        if w > 0, h > 0 { return w / h }
        return image.size.height > 0 ? image.size.width / image.size.height : 1
    }

    static func fit(aspect: CGFloat, in bounds: CGRect) -> CGRect {
        guard aspect > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        var size = CGSize(width: bounds.width, height: bounds.width / aspect)
        if size.height > bounds.height { size = CGSize(width: bounds.height * aspect, height: bounds.height) }
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    // MARK: - Navigation

    private func edgeButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(Color(white: 0.18), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.12)))
                .shadow(color: .black.opacity(0.3), radius: 8)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 22)
        .transition(.opacity)
    }

    private func step(_ delta: Int) {
        guard !zoomed, !closing, let i = index else { return }
        let j = i + delta
        guard entries.indices.contains(j) else { return }
        forward = delta > 0
        withAnimation(.spring(duration: 0.32, bounce: 0.05)) { currentId = entries[j].id }
    }

    /// Two-finger horizontal swipes on the trackpad (and Magic Mouse) move between items, like Photos.
    private func installSwipeMonitor() {
        guard swipeMonitor == nil else { return }
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard !zoomed, !closing, event.hasPreciseScrollingDeltas else { return event }
            if event.phase == .began { swipeAccumulated = 0; swipeConsumed = false }
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) || swipeAccumulated != 0 else { return event }
            if event.phase == .changed || event.phase == .began {
                swipeAccumulated += event.scrollingDeltaX
                if !swipeConsumed && abs(swipeAccumulated) > 60 {
                    swipeConsumed = true
                    step(swipeAccumulated > 0 ? -1 : 1)
                }
            }
            if event.phase == .ended || event.phase == .cancelled { swipeAccumulated = 0 }
            return nil
        }
    }

    private func removeSwipeMonitor() {
        if let swipeMonitor { NSEvent.removeMonitor(swipeMonitor) }
        swipeMonitor = nil
    }

    /// Decodes the neighbours' full images, and fetches the start of adjacent cloud videos once the one on screen
    /// plays smoothly (so they never slow it down).
    private func prefetchNeighbours() {
        guard let i = index else { prefetcher.cancel(); return }
        let screen = NSScreen.main.map { CGSize(width: $0.frame.width * $0.backingScaleFactor * 1.5, height: $0.frame.height * $0.backingScaleFactor * 1.5) }
            ?? CGSize(width: 4096, height: 4096)
        var videoItems: [MediaItem] = []
        for j in [i + 1, i - 1, i + 2] where entries.indices.contains(j) {
            let e = entries[j]
            ViewerImageCache.shared.preload(e, target: screen)
            if let item = e.item, e.isCloudOnly, item.kind == .video, item.isViewableFromCloud { videoItems.append(item) }
        }
        let current = entries[i]
        let videos = self.videos
        prefetcher.schedule(videoItems) {
            guard current.isCloudOnly, current.isVideo else { return true }
            return videos.sessions[current.id]?.player.currentItem?.hasPlentyBuffered == true
        }
    }
}

extension Notification.Name {
    static let macViewerTogglePlay = Notification.Name("Memvo.macViewerTogglePlay")
    static let macViewerClose = Notification.Name("Memvo.macViewerClose")
}

/// One item: zoomable photo, Live Photo or video, from Photos or from Telegram.
struct MacViewerPage: View {
    let entry: GalleryEntry
    let isCurrent: Bool
    @Binding var zoomed: Bool

    enum Content {
        case loading(PlatformImage?)
        case image(PlatformImage)
        case live(PHLivePhoto, still: PlatformImage?)
        case video(AVPlayer)
        case unavailable(String, PlatformImage?)
    }

    @State private var content: Content
    /// A cloud video's player and quality (original or fast version).
    @State private var session: CloudVideoSession?
    @EnvironmentObject private var videos: ViewerVideoSessions
    @State private var poster: PlatformImage?
    @State private var videoReady = false
    @State private var liveControl = LiveControl()
    @State private var showSpinner = false

    init(entry: GalleryEntry, isCurrent: Bool, zoomed: Binding<Bool>) {
        self.entry = entry
        self.isCurrent = isCurrent
        _zoomed = zoomed
        // Start from the grid tile's image, so the page is never black while the full image loads.
        let tile = ThumbnailPipeline.shared.cached(entry)?.image
        _content = State(initialValue: .loading(tile))
        _poster = State(initialValue: tile)
    }

    var body: some View {
        ZStack {
            switch content {
            case .loading(let placeholder):
                if let placeholder { Image(platformImage: placeholder).resizable().scaledToFit() }
                if showSpinner { spinner.transition(.opacity) }
            case .image(let image):
                ZoomableImage(image: image, zoomed: isCurrent ? $zoomed : .constant(false))
            case .live(let live, _):
                MacLivePhotoView(livePhoto: live, control: liveControl)
                    .overlay(alignment: .topLeading) { LiveBadge(control: liveControl).padding(16) }
            case .video(let player):
                MacPlayerView(player: player) { videoReady = true }
                    .overlay {
                        if !videoReady {
                            ZStack {
                                Color.black
                                if let poster { Image(platformImage: poster).resizable().scaledToFit() }
                                spinner
                            }
                            .allowsHitTesting(false)
                        }
                    }
                    .overlay { if let session { VideoSwitchingOverlay(session: session) } }
                    .overlay(alignment: .topTrailing) {
                        if let session { VideoQualityMenu(session: session).padding(16) }
                    }
                    .onAppear { if isCurrent { player.play() } }
                    .onChange(of: isCurrent) { _, now in if now { player.play() } else { player.pause() } }
                    .onDisappear {
                        player.pause()
                        if session != nil { videos.close(entry.id) }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .macViewerTogglePlay)) { note in
                        guard isCurrent else { return }
                        if player.timeControlStatus == .playing { player.pause() } else { player.play() }
                    }
            case .unavailable(let reason, let placeholder):
                VStack(spacing: 16) {
                    if let placeholder { Image(platformImage: placeholder).resizable().scaledToFit().frame(maxHeight: 320).opacity(0.6) }
                    Label(reason, systemImage: "icloud.slash")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: entry.id) { await load() }
        .task(id: entry.id) {
            // Only slow loads get a spinner; fast ones would just flicker.
            try? await Task.sleep(nanoseconds: 450_000_000)
            withAnimation(.easeIn(duration: 0.2)) { showSpinner = true }
        }
    }

    private var spinner: some View {
        ProgressView().controlSize(.large).tint(.white)
            .padding(18)
            .background(.black.opacity(0.35), in: Circle())
    }

    private func load() async {
        let env = AppEnvironment.shared
        let screen = await MainActor.run { () -> CGSize in
            let s = NSScreen.main ?? NSScreen.screens.first
            let scale = s?.backingScaleFactor ?? 2
            let size = s?.frame.size ?? CGSize(width: 1728, height: 1117)
            return CGSize(width: size.width * scale, height: size.height * scale)
        }
        let target = CGSize(width: screen.width * 1.5, height: screen.height * 1.5)
        if !entry.isVideo, !entry.isLive, let ready = ViewerImageCache.shared.image(for: entry.id) {
            content = .image(ready)
            return
        }

        if let asset = entry.asset {
            let preview = await env.photos.image(for: asset, targetSize: CGSize(width: 600, height: 600), mode: .fastFormat) ?? poster
            poster = preview
            content = .loading(preview)
            if asset.mediaType == .video {
                if let item = await Self.playerItem(for: asset) {
                    content = .video(AVPlayer(playerItem: item))
                } else {
                    content = .unavailable("Couldn't load this video.", preview)
                }
            } else if asset.mediaSubtypes.contains(.photoLive), let live = await Self.livePhoto(for: asset, size: target) {
                content = .live(live, still: preview)
            } else if let image = await env.photos.image(for: asset, targetSize: target) {
                content = .image(image)
                ViewerImageCache.shared.store(image, for: entry.id)
            } else {
                content = .unavailable("Couldn't load this photo.", preview)
            }
            return
        }

        guard let item = entry.item else { return }
        #if DEBUG
        appLog("Viewer: \(item.filename) kind \(item.kind) \(item.pixelWidth)x\(item.pixelHeight)")
        #endif
        let thumb = (try? await env.media.thumbnail(for: item)) ?? poster
        poster = thumb
        content = .loading(thumb)
        guard item.isViewableFromCloud else {
            content = .unavailable("This item isn't fully in your Telegram library yet.", thumb)
            return
        }
        do {
            switch item.kind {
            case .video:
                // Stream byte ranges straight from Telegram; play the edit when there is one, like Photos, or the
                // fast version on a slow or metered connection (Settings → Video quality).
                let s = videos.open(entry.id, item: item, reader: env.reader)
                session = s
                content = .video(s.player)
            case .livePhoto:
                let url = try await env.media.displayed(for: item)
                if let image = await Self.decode(url, maxPixel: max(target.width, target.height)) { content = .image(image) }
                if let video = try? await env.media.original(for: item, role: .pairedVideo),
                   let live = await Self.livePhoto(urls: [url, video]) {
                    content = .live(live, still: nil)
                }
            case .photo:
                let opened = Date(), cached = env.media.hasDisplayed(item)
                let url = try await env.media.displayed(for: item)
                if let image = await Self.decode(url, maxPixel: max(target.width, target.height)) {
                    content = .image(image)
                    ViewerImageCache.shared.store(image, for: entry.id)
                    CloudMediaService.logPhotoTiming(item, opened: opened, wasCached: cached)
                } else {
                    content = .unavailable("This file format can't be previewed. Use Export to open it in another app.", thumb)
                }
            }
        } catch {
            content = .unavailable(error.localizedDescription, thumb)
        }
    }

    static func decode(_ url: URL, maxPixel: CGFloat) async -> PlatformImage? {
        await Task.detached(priority: .userInitiated) { CloudMediaService.downsampled(url, maxPixel: maxPixel) }.value
    }

    static func playerItem(for asset: PHAsset) async -> AVPlayerItem? {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic
        return await withCheckedContinuation { cont in
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in cont.resume(returning: item) }
        }
    }

    static func livePhoto(for asset: PHAsset, size: CGSize) async -> PHLivePhoto? {
        let options = PHLivePhotoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        return await withCheckedContinuation { cont in
            var resumed = false
            PHImageManager.default().requestLivePhoto(for: asset, targetSize: size, contentMode: .aspectFit, options: options) { live, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !degraded, !resumed else { return }
                resumed = true
                cont.resume(returning: live)
            }
        }
    }

    static func livePhoto(urls: [URL]) async -> PHLivePhoto? {
        await withCheckedContinuation { cont in
            var resumed = false
            PHLivePhoto.request(withResourceFileURLs: urls, placeholderImage: nil, targetSize: .zero, contentMode: .aspectFit) { live, info in
                let degraded = (info[PHLivePhotoInfoIsDegradedKey] as? Bool) ?? false
                let failed = info[PHLivePhotoInfoErrorKey] != nil
                guard !resumed, !degraded || failed else { return }
                resumed = true
                cont.resume(returning: failed ? nil : live)
            }
        }
    }
}

// MARK: - Zoomable image

/// NSScrollView magnification: trackpad pinch, ⌘-scroll, double-click to zoom in at the pointer and back.
struct ZoomableImage: NSViewRepresentable {
    let image: NSImage
    @Binding var zoomed: Bool

    func makeCoordinator() -> Coordinator { Coordinator(zoomed: $zoomed) }

    func makeNSView(context: Context) -> ZoomScrollView {
        let scroll = ZoomScrollView()
        scroll.allowsMagnification = true
        scroll.minMagnification = 1
        scroll.maxMagnification = 8
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        // SwiftUI already lays the page out below the toolbar; AppKit's own inset would push the photo down again.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.contentView = CenteringClipView()
        scroll.contentView.drawsBackground = false
        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = true
        imageView.setAccessibilityLabel("Photo")
        scroll.documentView = imageView
        let doubleClick = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleClicked(_:)))
        doubleClick.numberOfClicksRequired = 2
        scroll.addGestureRecognizer(doubleClick)
        scroll.onMagnify = { [weak coordinator = context.coordinator] m in coordinator?.update(m) }
        return scroll
    }

    func updateNSView(_ scroll: ZoomScrollView, context: Context) {
        if let iv = scroll.documentView as? NSImageView, iv.image !== image { iv.image = image }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ZoomScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    final class Coordinator: NSObject {
        let zoomed: Binding<Bool>
        init(zoomed: Binding<Bool>) { self.zoomed = zoomed }

        func update(_ magnification: CGFloat) {
            let isZoomed = magnification > 1.01
            if zoomed.wrappedValue != isZoomed { zoomed.wrappedValue = isZoomed }
        }

        @objc func doubleClicked(_ g: NSClickGestureRecognizer) {
            guard let scroll = g.view as? NSScrollView, let doc = scroll.documentView else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.allowsImplicitAnimation = true
                if scroll.magnification > 1.01 {
                    scroll.animator().magnification = 1
                } else {
                    scroll.animator().setMagnification(2.5, centeredAt: g.location(in: doc))
                }
            }
            update(scroll.magnification > 1.01 ? 1 : 2.5)
        }
    }
}

/// Keeps the document the size of the visible area at 1×, and hands horizontal swipes to the pager when not zoomed.
final class ZoomScrollView: NSScrollView {
    var onMagnify: (CGFloat) -> Void = { _ in }

    override var magnification: CGFloat {
        didSet { onMagnify(magnification) }
    }

    override func layout() {
        super.layout()
        if let doc = documentView, doc.frame.size != contentSize, magnification <= 1.01 {
            doc.setFrameSize(contentSize)
        }
    }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        onMagnify(magnification)
    }

    override func endGesture(with event: NSEvent) {
        super.endGesture(with: event)
        onMagnify(magnification)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let factor = 1 + event.scrollingDeltaY * 0.01
            setMagnification(min(maxMagnification, max(minMagnification, magnification * factor)),
                             centeredAt: documentView?.convert(event.locationInWindow, from: nil) ?? .zero)
            onMagnify(magnification)
        } else if magnification <= 1.01 {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// Centres the image while it's smaller than the visible area.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
        if rect.height > doc.frame.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        return rect
    }
}

// MARK: - Video

/// AVPlayerView with the floating QuickTime controls: scrubbing, Picture in Picture, AirPlay, speed.
struct MacPlayerView: NSViewRepresentable {
    let player: AVPlayer
    var onReadyForDisplay: () -> Void = {}

    final class Coordinator {
        var observation: NSKeyValueObservation?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.allowsPictureInPicturePlayback = true
        view.showsFullScreenToggleButton = true
        view.allowsMagnification = true
        view.updatesNowPlayingInfoCenter = true
        let ready = onReadyForDisplay
        context.coordinator.observation = view.observe(\.isReadyForDisplay, options: [.initial, .new]) { v, _ in
            if v.isReadyForDisplay { DispatchQueue.main.async { ready() } }
        }
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    /// AVPlayerView reports the video's pixel size as its intrinsic size; always take exactly the page instead.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AVPlayerView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        coordinator.observation = nil
        view.player?.pause()
    }
}

// MARK: - Live Photo

/// Lets the SwiftUI LIVE badge start and stop playback of the AppKit view.
final class LiveControl {
    weak var view: PHLivePhotoView?
    func play() { view?.startPlayback(with: .full) }
    func stop() { view?.stopPlayback() }
}

struct MacLivePhotoView: NSViewRepresentable {
    let livePhoto: PHLivePhoto
    let control: LiveControl

    /// PHLivePhotoView reports the photo's pixel size as its intrinsic size; a plain container fills the page instead.
    final class Container: NSView {
        let live = PHLivePhotoView()
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    }

    func makeNSView(context: Context) -> Container {
        let container = Container()
        container.live.livePhoto = livePhoto
        container.live.contentMode = .aspectFit
        container.live.frame = container.bounds
        container.live.autoresizingMask = [.width, .height]
        container.live.setAccessibilityLabel("Live Photo. Point at LIVE to play.")
        container.addSubview(container.live)
        control.view = container.live
        return container
    }

    func updateNSView(_ container: Container, context: Context) {
        if container.live.livePhoto !== livePhoto { container.live.livePhoto = livePhoto }
        control.view = container.live
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Container, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

/// Apple Photos on the Mac plays a Live Photo while the pointer is over its LIVE badge.
struct LiveBadge: View {
    let control: LiveControl
    @State private var hovering = false

    var body: some View {
        Label("LIVE", systemImage: "livephoto")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.black.opacity(hovering ? 0.6 : 0.4), in: Capsule())
            .contentShape(Capsule())
            .onHover { inside in
                hovering = inside
                if inside { control.play() } else { control.stop() }
            }
            .onTapGesture { control.play() }
            .help("Point here to play the Live Photo")
    }
}
