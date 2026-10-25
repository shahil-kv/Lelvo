import SwiftUI
import AVKit
import Photos
import PhotosUI
import MapKit
import MemvoCore

struct ViewerView: View {
    let entries: [GalleryEntry]
    /// Reports the item on screen, so the grid can follow and the close animation returns to it.
    var onPageChange: (String) -> Void = { _ in }
    @State private var currentId: String?
    @State private var chromeHidden = false
    @State private var zoomed = false
    @State private var showInfo = false
    @State private var share: ShareItems?
    @State private var message: GalleryAlert?
    @State private var busy = false
    @State private var confirmDelete = false
    @StateObject private var videos = ViewerVideoSessions()
    @State private var prefetcher = NeighbourPrefetcher()
    @Environment(\.dismiss) private var dismiss

    /// Set when presented from UIKit (the grid); SwiftUI presentations use `dismiss`.
    var onClose: (() -> Void)?

    init(entries: [GalleryEntry], startId: String, onPageChange: @escaping (String) -> Void = { _ in }, onClose: (() -> Void)? = nil) {
        self.entries = entries
        self.onPageChange = onPageChange
        self.onClose = onClose
        _currentId = State(initialValue: startId)
    }

    private var current: GalleryEntry? { entries.first { $0.id == currentId } }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(entries) { entry in
                        ViewerPage(entry: entry, isCurrent: entry.id == currentId, chromeHidden: chromeHidden, zoomed: $zoomed)
                            .containerRelativeFrame([.horizontal, .vertical])
                            .id(entry.id)
                            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { chromeHidden.toggle() } }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $currentId)
            .scrollIndicators(.hidden)
            .scrollDisabled(zoomed)
            .background(Color.black.ignoresSafeArea())
            .ignoresSafeArea()
            .onAppear {
                if let currentId { proxy.scrollTo(currentId) }
                prefetchNeighbours(of: currentId)
            }
            .onChange(of: currentId) { _, id in
                prefetchNeighbours(of: id)
                if let id { onPageChange(id) }
            }
        }
        .environmentObject(videos)
        .onDisappear { videos.closeAll() }
        .overlay(alignment: .top) { if !chromeHidden { topBar.transition(.opacity) } }
        .overlay(alignment: .bottom) { if !chromeHidden { bottomBar.transition(.opacity) } }
        .overlay { if busy { ProgressView().tint(.white).scaleEffect(1.4) } }
        .statusBarHidden(chromeHidden)
        .background(CloseObserver())
        .sheet(isPresented: $showInfo) {
            if let current { InfoSheet(entry: current).presentationDetents([.medium, .large]) }
        }
        .sheet(item: $share) { ActivityView(items: $0.urls).presentationDetents([.medium, .large]) }
        .alert(item: $message) { a in Alert(title: Text(a.title), message: Text(a.message)) }
        .alert("Delete from your backup?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete from Backup", role: .destructive) { Task { await deleteCurrent() } }
        } message: {
            Text("It moves to Recently Deleted in Memvo and is removed from your Telegram library after 30 days. If it's still on this iPhone, it stays there.")
        }
    }

    private var topBar: some View {
        ZStack {
            if let current {
                VStack(spacing: 1) {
                    Text(Format.date(current.date, style: .medium, time: .none)).font(.subheadline.weight(.semibold))
                    HStack(spacing: 4) {
                        Text(Format.date(current.date, style: .none, time: .short))
                        Image(systemName: current.badge.symbol).foregroundStyle(current.badge.tint)
                            .accessibilityLabel(current.badge.label)
                    }
                    .font(.caption)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 4)
            }
            HStack {
                Button {
                NotificationCenter.default.post(name: .viewerWillClose, object: nil)
                close()
            } label: {
                    Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(.white)
                        .frame(width: 36, height: 36).background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Close")
                Spacer()
                if let currentId, let session = videos.sessions[currentId] {
                    VideoQualityMenu(session: session)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 24)
        .background(LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    private var bottomBar: some View {
        HStack {
            Button { Task { await shareCurrent() } } label: { Image(systemName: "square.and.arrow.up") }
                .accessibilityLabel("Share")
            Spacer()
            if let current, current.isCloudOnly, current.item?.isViewableFromCloud == true {
                Button { Task { await saveCurrent() } } label: { Image(systemName: "square.and.arrow.down") }
                    .accessibilityLabel("Save to Photos")
                Spacer()
            }
            if let current, let id = current.asset?.localIdentifier, [.phoneOnly, .failed, .waiting].contains(current.badge) {
                Button { backUp(id) } label: { Image(systemName: "icloud.and.arrow.up") }
                    .accessibilityLabel("Back up to the cloud")
                Spacer()
            }
            Button { showInfo = true } label: { Image(systemName: "info.circle") }
                .accessibilityLabel("Info")
            Spacer()
            Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                .accessibilityLabel("Delete from cloud")
                .disabled(current?.item?.status != .backedUp)
        }
        .font(.title3)
        .foregroundStyle(.white)
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 8)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    /// Fetches the first few MB of adjacent cloud videos so swiping to them starts playback instantly.
    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    /// Fetches the start of adjacent cloud videos once the one on screen plays smoothly, so swiping to them starts
    /// playback at once without slowing the current one down.
    private func prefetchNeighbours(of id: String?) {
        guard let id, let i = entries.firstIndex(where: { $0.id == id }) else { prefetcher.cancel(); return }
        let items = [i + 1, i - 1].filter(entries.indices.contains).compactMap { j -> MediaItem? in
            guard let item = entries[j].item, entries[j].isCloudOnly, item.kind == .video, item.isViewableFromCloud else { return nil }
            return item
        }
        let current = entries[i]
        let videos = self.videos
        prefetcher.schedule(items) {
            guard current.isCloudOnly, current.isVideo else { return true }
            return videos.sessions[current.id]?.player.currentItem?.hasPlentyBuffered == true
        }
    }

    private func backUp(_ localIdentifier: String) {
        Task {
            _ = await Task.detached { AppEnvironment.shared.engine.enqueue(localIdentifiers: [localIdentifier]) }.value
            Haptics.success()
            ContinuedBackup.start()
            message = GalleryAlert(title: "Backing up", message: "This item is queued; progress is on the Backup tab.")
        }
    }

    private func shareCurrent() async {
        guard let current else { return }
        busy = true
        defer { busy = false }
        do { share = ShareItems(urls: [try await GalleryActions.shareableFile(for: current)]) }
        catch { message = GalleryAlert(title: "Can't share", message: error.localizedDescription) }
    }

    private func saveCurrent() async {
        guard let item = current?.item else { return }
        busy = true
        defer { busy = false }
        do {
            try await GalleryActions.saveToPhotos(item)
            Haptics.success()
            message = GalleryAlert(title: "Saved", message: "Saved to your photo library.")
        } catch {
            Haptics.error()
            message = GalleryAlert(title: "Couldn't save", message: error.localizedDescription)
        }
    }

    private func deleteCurrent() async {
        guard let item = current?.item else { return }
        busy = true
        defer { busy = false }
        do {
            try await GalleryActions.deleteFromCloud([item])
            Haptics.success()
            if current?.isCloudOnly == true { close() }
        } catch {
            message = GalleryAlert(title: "Couldn't delete", message: error.localizedDescription)
        }
    }
}

/// Loads and shows one item: zoomable photo, Live Photo or video, from the phone or from Telegram.
struct ViewerPage: View {
    let entry: GalleryEntry
    let isCurrent: Bool
    let chromeHidden: Bool
    @Binding var zoomed: Bool

    enum Content {
        case loading(UIImage?)
        case image(UIImage)
        case live(PHLivePhoto)
        case video(AVPlayer)
        case unavailable(String, UIImage?)
    }

    @State private var content: Content = .loading(nil)
    /// A cloud video's player and quality (original or fast version).
    @State private var session: CloudVideoSession?
    @EnvironmentObject private var videos: ViewerVideoSessions
    @State private var pip: AVPictureInPictureController?
    /// Shown over a video until its first frame is on screen (instead of a black page).
    @State private var poster: UIImage?
    @State private var videoReady = false
    @State private var trace: VideoTrace?

    var body: some View {
        ZStack {
            switch content {
            case .loading(let placeholder):
                if let placeholder { Image(uiImage: placeholder).resizable().scaledToFit() }
                ProgressView().tint(.white).padding(14).background(.black.opacity(0.35), in: Circle())
            case .image(let image):
                ZoomableImageView(image: image, zoomed: $zoomed)
            case .live(let live):
                LivePhotoView(livePhoto: live)
            case .video(let player):
                PlayerView(player: player, zoomed: $zoomed, onPictureInPicture: { pip = $0 }, onReadyForDisplay: { videoReady = true; trace?.firstFrame() })
                    .overlay {
                        if !videoReady {
                            ZStack {
                                Color.black
                                if let poster { Image(uiImage: poster).resizable().scaledToFit() }
                                ProgressView().tint(.white).padding(14).background(.black.opacity(0.35), in: Circle())
                            }
                            .allowsHitTesting(false)
                        }
                    }
                    .overlay { if let session { VideoSwitchingOverlay(session: session) } }
                    .overlay(alignment: .bottom) {
                        if !chromeHidden { VideoControls(player: player, pip: pip).padding(.bottom, 112).transition(.opacity) }
                    }
                    .onChange(of: session?.quality) { _, q in
                        // A new item after a quality switch: trace it like the first.
                        if let q, let item = player.currentItem, let name = entry.item?.filename {
                            trace = VideoTrace(item: item, name: name, source: q == .original ? "cloud original" : "cloud fast version")
                        }
                    }
                    .onAppear { if isCurrent { player.play() } }
                    .onChange(of: isCurrent) { _, now in if now { player.play() } else { player.pause() } }
                    .onDisappear {
                        player.pause()
                        if session != nil { videos.close(entry.id) }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .viewerWillClose)) { _ in player.pause() }
                    .onReceive(NotificationCenter.default.publisher(for: .viewerCloseCancelled)) { _ in if isCurrent { player.play() } }
            case .unavailable(let reason, let placeholder):
                VStack(spacing: 16) {
                    if let placeholder { Image(uiImage: placeholder).resizable().scaledToFit().frame(maxHeight: 280) }
                    Label(reason, systemImage: "icloud.slash").foregroundStyle(.white).multilineTextAlignment(.center).padding()
                }
            }
        }
        .task(id: entry.id) { await load() }
        .onChange(of: isCurrent) { _, now in
            guard entry.asset == nil, let item = entry.item, item.kind == .video, item.isViewableFromCloud else { return }
            if now, session == nil {
                startCloudVideo(item)
            } else if !now, session != nil {
                // Swiped away: stop it and its download.
                videos.close(entry.id)
                session = nil
                videoReady = false
                content = .loading(poster)
            }
        }
    }

    private func load() async {
        let env = AppEnvironment.shared
        let screen = await MainActor.run { UIScreen.main.bounds.size }
        let target = CGSize(width: screen.width * 3, height: screen.height * 3)

        if let asset = entry.asset {
            let preview = await env.photos.image(for: asset, targetSize: CGSize(width: 400, height: 400), mode: .fastFormat)
            poster = preview
            content = .loading(preview)
            if asset.mediaType == .video {
                if let item = await Self.playerItem(for: asset) {
                    trace = VideoTrace(item: item, name: entry.item?.filename ?? "local video", source: "iPhone")
                    content = .video(AVPlayer(playerItem: item))
                }
                else { content = .unavailable("Couldn't load this video.", nil) }
            } else if asset.mediaSubtypes.contains(.photoLive), let live = await Self.livePhoto(for: asset, size: target) {
                content = .live(live)
            } else if let image = await env.photos.image(for: asset, targetSize: target) {
                content = .image(image)
            } else {
                content = .unavailable("Couldn't load this photo.", nil)
            }
            return
        }

        guard let item = entry.item else { return }
        let thumb = try? await env.media.thumbnail(for: item)
        poster = thumb
        content = .loading(thumb)
        guard item.isViewableFromCloud else {
            content = .unavailable("This item isn't fully in your Telegram library yet.", thumb)
            return
        }
        do {
            switch item.kind {
            case .video:
                // Only the page on screen gets a player: a paused player keeps downloading, and the pages next to it
                // would take bandwidth from the video being watched. Their start is prefetched instead.
                if isCurrent { startCloudVideo(item) }
            case .livePhoto:
                let url = try await env.media.displayed(for: item)
                if let image = await Self.decode(url, maxPixel: max(target.width, target.height)) { content = .image(image) }
                if let video = try? await env.media.original(for: item, role: .pairedVideo),
                   let live = await Self.livePhoto(urls: [url, video]) {
                    content = .live(live)
                }
            case .photo:
                // Progressive: thumbnail → screen-size decode → full detail when zooming.
                let url = try await env.media.displayed(for: item)
                if let image = await Self.decode(url, maxPixel: max(target.width, target.height)) {
                    content = .image(image)
                } else {
                    content = .unavailable("This file format can't be previewed. Use Share to open it in another app.", thumb)
                }
            }
        } catch {
            content = .unavailable(error.localizedDescription, thumb)
        }
    }

    /// Streams a cloud video from Telegram (no full download): the fast version when the connection can't carry the
    /// original (Settings → Video quality), and the edit rather than the original when it was edited in Photos.
    private func startCloudVideo(_ item: MediaItem) {
        let s = videos.open(entry.id, item: item, reader: AppEnvironment.shared.reader)
        session = s
        if let playerItem = s.player.currentItem {
            trace = VideoTrace(item: playerItem, name: item.filename,
                               source: s.quality == .original ? "cloud \(Format.bytes(item.fileSize))" : "cloud fast version")
        }
        content = .video(s.player)
    }

    static func decode(_ url: URL, maxPixel: CGFloat) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            CloudMediaService.downsampled(url, maxPixel: maxPixel)?.preparingForDisplay()
        }.value
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

/// UIScrollView-backed zoom: pinch, and double-tap to zoom in/out.
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    @Binding var zoomed: Bool

    func makeCoordinator() -> Coordinator { Coordinator(zoomed: $zoomed) }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.maximumZoomScale = 6
        scroll.minimumZoomScale = 1
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = .clear
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = "Photo"
        scroll.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            imageView.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor)
        ])
        context.coordinator.imageView = imageView
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        if context.coordinator.imageView?.image !== image { context.coordinator.imageView?.image = image }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var imageView: UIImageView?
        let zoomed: Binding<Bool>
        init(zoomed: Binding<Bool>) { self.zoomed = zoomed }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let isZoomed = scrollView.zoomScale > 1.01
            if zoomed.wrappedValue != isZoomed { zoomed.wrappedValue = isZoomed }
        }

        @objc func doubleTapped(_ g: UITapGestureRecognizer) {
            guard let scroll = g.view as? UIScrollView else { return }
            if scroll.zoomScale > 1.01 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let point = g.location(in: imageView)
                let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
}

/// PHLivePhotoView: press and hold to play, plus an explicit play button.
struct LivePhotoView: UIViewRepresentable {
    let livePhoto: PHLivePhoto

    /// PHLivePhotoView reports the live photo's pixel size as its intrinsic size, so SwiftUI laid it out
    /// several screens wide (photos opened zoomed in). A plain container has no intrinsic size and fills the page.
    final class Container: UIView {
        let live = PHLivePhotoView()
    }

    func makeUIView(context: Context) -> Container {
        let container = Container()
        container.backgroundColor = .clear
        let view = container.live
        view.contentMode = .scaleAspectFit
        view.livePhoto = livePhoto
        view.frame = container.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Live Photo. Touch and hold to play."
        container.addSubview(view)
        var style = UIButton.Configuration.plain()
        style.image = UIImage(systemName: "livephoto.play")
        style.title = "LIVE"
        style.imagePadding = 4
        style.baseForegroundColor = .white
        style.background.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        style.background.cornerRadius = 12
        style.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        let badge = UIButton(configuration: style)
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.addAction(UIAction { [weak view] _ in view?.startPlayback(with: .full) }, for: .touchUpInside)
        container.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            badge.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 64)
        ])
        return container
    }

    func updateUIView(_ container: Container, context: Context) {
        if container.live.livePhoto !== livePhoto { container.live.livePhoto = livePhoto }
    }

    /// Always exactly the space offered (the page), never the photo's own size.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Container, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

struct InfoSheet: View {
    let entry: GalleryEntry

    private var coordinate: CLLocationCoordinate2D? {
        if let loc = entry.asset?.location { return loc.coordinate }
        if let lat = entry.item?.latitude, let lon = entry.item?.longitude { return CLLocationCoordinate2D(latitude: lat, longitude: lon) }
        return nil
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("Date", Format.date(entry.date, style: .full, time: .short))
                    if let item = entry.item {
                        row("File name", item.filename)
                        row("Size", Format.bytes(item.fileSize + (item.pairedVideoSize ?? 0)))
                    }
                    let w = entry.asset?.pixelWidth ?? entry.item?.pixelWidth ?? 0
                    let h = entry.asset?.pixelHeight ?? entry.item?.pixelHeight ?? 0
                    if w > 0 { row("Dimensions", "\(w) × \(h)") }
                    if entry.isVideo, let d = entry.duration { row("Duration", Duration.seconds(d).formatted(.time(pattern: .minuteSecond))) }
                    if let codec = entry.item?.codec { row("Codec", codec.uppercased()) }
                    if let hdr = entry.item?.hdr, hdr > 0 { row("Dynamic range", hdr == 2 ? "Dolby Vision" : "HDR") }
                }
                Section("Backup") {
                    Label(entry.badge.label, systemImage: entry.badge.symbol)
                    if let item = entry.item {
                        if let up = item.uploadedAt { row("Uploaded", Format.date(up)) }
                        if item.encrypted { Label("End-to-end encrypted", systemImage: "lock.fill") }
                        if let v = item.verifiedAt { row("Verified", Format.relative(v)) }
                        if let e = item.lastError { Text(e).font(.footnote).foregroundStyle(.orange) }
                    }
                }
                if let coordinate {
                    Section("Location") {
                        Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 2000, longitudinalMeters: 2000))) {
                            Marker("", coordinate: coordinate)
                        }
                        .frame(height: 200)
                        .listRowInsets(EdgeInsets())
                        row("Coordinates", String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude))
                    }
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title, value: value)
    }
}

/// Bare AVPlayerLayer: no system controls to collide with ours; Picture in Picture via the layer.
struct PlayerView: UIViewRepresentable {
    let player: AVPlayer
    /// Pinch/double-tap zoom like Photos; paging is disabled while zoomed.
    var zoomed: Binding<Bool> = .constant(false)
    var onPictureInPicture: (AVPictureInPictureController?) -> Void = { _ in }
    var onReadyForDisplay: () -> Void = {}

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var pip: AVPictureInPictureController?
        var readyObservation: NSKeyValueObservation?
        var layerView: LayerView?
        var zoomed: Binding<Bool>
        init(zoomed: Binding<Bool>) { self.zoomed = zoomed }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { layerView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let isZoomed = scrollView.zoomScale > 1.01
            if zoomed.wrappedValue != isZoomed { zoomed.wrappedValue = isZoomed }
        }

        @objc func doubleTapped(_ g: UITapGestureRecognizer) {
            guard let scroll = g.view as? UIScrollView else { return }
            if scroll.zoomScale > 1.01 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let point = g.location(in: layerView)
                let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(zoomed: zoomed) }

    func makeUIView(context: Context) -> UIScrollView {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.maximumZoomScale = 5
        scroll.minimumZoomScale = 1
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = .black

        let view = LayerView()
        view.backgroundColor = .black
        view.playerLayer?.player = player
        view.playerLayer?.videoGravity = .resizeAspect
        view.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(view)
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            view.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            view.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            view.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            view.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor)
        ])
        context.coordinator.layerView = view
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)

        player.allowsExternalPlayback = true
        if AVPictureInPictureController.isPictureInPictureSupported(), let layer = view.playerLayer {
            let pip = AVPictureInPictureController(playerLayer: layer)
            pip?.canStartPictureInPictureAutomaticallyFromInline = true
            context.coordinator.pip = pip
        }
        let pip = context.coordinator.pip
        DispatchQueue.main.async { onPictureInPicture(pip) }
        let ready = onReadyForDisplay
        context.coordinator.readyObservation = view.playerLayer?.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
            if layer.isReadyForDisplay { DispatchQueue.main.async { ready() } }
        }
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.zoomed = zoomed
        if let layer = context.coordinator.layerView?.playerLayer, layer.player !== player { layer.player = player }
    }
}

/// Hidden system AirPlay picker, opened from the ⋯ menu.
private struct AirPlayPicker: UIViewRepresentable {
    let trigger: Int

    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.prioritizesVideoDevices = true
        v.alpha = 0.011
        return v
    }

    func updateUIView(_ v: AVRoutePickerView, context: Context) {
        guard trigger != context.coordinator.last else { return }
        context.coordinator.last = trigger
        (v.subviews.first { $0 is UIButton } as? UIButton)?.sendActions(for: .touchUpInside)
    }

    final class Coordinator { var last = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }
}

/// Play/pause, scrubber with elapsed and remaining time, and mute, styled like the Photos video bar.
struct VideoControls: View {
    let player: AVPlayer
    let pip: AVPictureInPictureController?
    @StateObject private var state = PlaybackState()
    @State private var speed: Float = 1
    @State private var airPlayTrigger = 0

    private static let speeds: [Float] = [0.5, 1, 1.25, 1.5, 2]
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        HStack(spacing: 12) {
            Button { if state.isPlaying { player.pause() } else { player.play() } } label: {
                ZStack {
                    if state.isBuffering {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: state.isPlaying ? "pause.fill" : "play.fill").font(.title3)
                    }
                }
                .frame(width: 28, height: 28)
            }
            .accessibilityLabel(state.isPlaying ? "Pause" : "Play")
            Text(Self.time(scrubbing ? scrubValue : state.current)).font(.caption.monospacedDigit())
            Slider(value: Binding(get: { scrubbing ? scrubValue : state.current }, set: { scrubValue = $0 }),
                   in: 0...max(state.duration, 0.1)) { editing in
                scrubbing = editing
                if !editing { player.seek(to: CMTime(seconds: scrubValue, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
                else { scrubValue = state.current }
            }
            .tint(.white)
            .onChange(of: scrubValue) { _, v in
                if scrubbing { player.seek(to: CMTime(seconds: v, preferredTimescale: 600), toleranceBefore: .positiveInfinity, toleranceAfter: .positiveInfinity) }
            }
            Text("-" + Self.time(max(0, state.duration - (scrubbing ? scrubValue : state.current)))).font(.caption.monospacedDigit())
            Button { player.isMuted.toggle(); state.isMuted = player.isMuted } label: {
                Image(systemName: state.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.body).frame(width: 28)
            }
            .accessibilityLabel(state.isMuted ? "Unmute" : "Mute")
            Menu {
                Menu {
                    ForEach(Self.speeds, id: \.self) { s in
                        Button { setSpeed(s) } label: {
                            if s == speed { Label(Self.speedLabel(s), systemImage: "checkmark") } else { Text(Self.speedLabel(s)) }
                        }
                    }
                } label: { Label("Playback Speed · \(Self.speedLabel(speed))", systemImage: "gauge.with.dots.needle.67percent") }
                if let pip {
                    Button { pip.startPictureInPicture() } label: { Label("Picture in Picture", systemImage: "pip.enter") }
                }
                Button { airPlayTrigger += 1 } label: { Label("AirPlay", systemImage: "airplayvideo") }
            } label: {
                Image(systemName: "ellipsis").font(.body.weight(.semibold)).frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .accessibilityLabel("More options")
            .background(AirPlayPicker(trigger: airPlayTrigger).frame(width: 1, height: 1))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 16)
        .onAppear { state.attach(player) }
        .onDisappear { state.detach() }
    }

    private func setSpeed(_ s: Float) {
        speed = s
        player.defaultRate = s
        if state.isPlaying { player.rate = s }
    }

    static func speedLabel(_ s: Float) -> String {
        s == 1 ? "Normal" : (s.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(s))×" : "\(s)×")
    }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let s = Int(seconds.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

@MainActor
final class PlaybackState: ObservableObject {
    @Published var current: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false
    /// Waiting for data (slow network): shown as a spinner instead of the play/pause icon.
    @Published var isBuffering = false
    @Published var isMuted = false
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private weak var player: AVPlayer?

    func attach(_ player: AVPlayer) {
        detach()
        self.player = player
        isMuted = player.isMuted
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                // While waiting for data the player can report an invalid time; keep the last position
                // instead of snapping the clock and slider back to 0:00.
                guard t.isValid, t.isNumeric, t.seconds.isFinite, t.seconds >= 0 else { return }
                self.current = t.seconds
                if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 { self.duration = d }
            }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] p, _ in
            let playing = p.timeControlStatus != .paused
            let buffering = p.timeControlStatus == .waitingToPlayAtSpecifiedRate
            Task { @MainActor in
                self?.isPlaying = playing
                self?.isBuffering = buffering
            }
        }
    }

    func detach() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation = nil
    }
}

extension Notification.Name {
    /// The viewer started closing (swipe down or ✕): stop sound right away, not after the animation.
    static let viewerWillClose = Notification.Name("ViewerWillClose")
    /// An interactive close was cancelled; the viewer stays.
    static let viewerCloseCancelled = Notification.Name("ViewerCloseCancelled")
    /// The photo grid is on screen (it preloads the cloud videos it shows).
    static let galleryDidAppear = Notification.Name("GalleryDidAppear")
}

/// UIKit tells the presented screen `viewWillDisappear` as soon as a dismissal starts (including the
/// interactive swipe-down), and `viewDidAppear` again if the swipe is cancelled.
private struct CloseObserver: UIViewControllerRepresentable {
    final class Controller: UIViewController {
        private var closing = false
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            closing = true
            NotificationCenter.default.post(name: .viewerWillClose, object: nil)
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            if closing { NotificationCenter.default.post(name: .viewerCloseCancelled, object: nil) }
            closing = false
        }
    }
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ vc: Controller, context: Context) {}
}

/// Logs what each opened video does: time to first frame, stalls, and AVPlayer's own errors, which are
/// otherwise silent (a black screen with no log line).
final class VideoTrace {
    private let name: String
    private let source: String
    private let opened = Date()
    private var logged = false
    private var statusObservation: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []

    init(item: AVPlayerItem, name: String, source: String) {
        self.name = name
        self.source = source
        appLog("Video open: \(name) (\(source))")
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self, item.status == .failed else { return }
            let e = item.error as NSError?
            AppLog.shared.error("Video failed: \(self.name) after \(self.elapsed): \(e?.localizedDescription ?? "unknown") [\(e?.domain ?? "") \(e?.code ?? 0)] \(e?.userInfo[NSUnderlyingErrorKey] ?? "")")
        }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: item, queue: .main) { [weak self] _ in
            guard let self else { return }
            AppLog.shared.warn("Video stalled: \(self.name) at \(String(format: "%.1f", item.currentTime().seconds)) s, buffered \(String(format: "%.1f", Self.buffered(item))) s")
        })
        observers.append(nc.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] note in
            guard let self else { return }
            let e = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
            AppLog.shared.error("Video stopped early: \(self.name): \(e?.localizedDescription ?? "unknown") [\(e?.domain ?? "") \(e?.code ?? 0)]")
        })
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    private var elapsed: String { String(format: "%.1f s", Date().timeIntervalSince(opened)) }

    func firstFrame() {
        guard !logged else { return }
        logged = true
        appLog("Video first frame: \(name) after \(elapsed)")
    }

    private static func buffered(_ item: AVPlayerItem) -> Double {
        let now = item.currentTime()
        for r in item.loadedTimeRanges.map(\.timeRangeValue) where r.containsTime(now) {
            return (r.end - now).seconds
        }
        return 0
    }
}
