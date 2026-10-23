import SwiftUI
import AVKit
import Photos
import PhotosUI
import MapKit
import CloudGalleryCore

struct ViewerView: View {
    let entries: [GalleryEntry]
    @State private var currentId: String?
    @State private var chromeHidden = false
    @State private var zoomed = false
    @State private var showInfo = false
    @State private var share: ShareItems?
    @State private var message: GalleryAlert?
    @State private var busy = false
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    init(entries: [GalleryEntry], startId: String) {
        self.entries = entries
        _currentId = State(initialValue: startId)
    }

    private var current: GalleryEntry? { entries.first { $0.id == currentId } }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(entries) { entry in
                        ViewerPage(entry: entry, isCurrent: entry.id == currentId, zoomed: $zoomed)
                            .containerRelativeFrame([.horizontal, .vertical])
                            .id(entry.id)
                            .onTapGesture { withAnimation { chromeHidden.toggle() } }
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
            .onAppear { if let currentId { proxy.scrollTo(currentId) } }
            .onChange(of: currentId) { _, id in prefetchNeighbours(of: id) }
        }
        .overlay(alignment: .top) { if !chromeHidden { topBar } }
        .overlay(alignment: .bottom) { if !chromeHidden { bottomBar } }
        .overlay { if busy { ProgressView().tint(.white).scaleEffect(1.4) } }
        .statusBarHidden(chromeHidden)
        .sheet(isPresented: $showInfo) {
            if let current { InfoSheet(entry: current).presentationDetents([.medium, .large]) }
        }
        .sheet(item: $share) { ActivityView(items: $0.urls).presentationDetents([.medium, .large]) }
        .alert(item: $message) { a in Alert(title: Text(a.title), message: Text(a.message)) }
        .confirmationDialog("Delete from your Telegram backup?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete from cloud", role: .destructive) { Task { await deleteCurrent() } }
        } message: {
            Text("The photo stays on this iPhone if it's still here, and will be backed up again next time.")
        }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).padding(10).background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Close")
            Spacer()
            if let current {
                VStack(spacing: 2) {
                    Text(Format.date(current.date, style: .medium, time: .none)).font(.subheadline.bold())
                    Text(Format.date(current.date, style: .none, time: .short)).font(.caption)
                }
                .foregroundStyle(.white)
                Spacer()
                BadgeView(badge: current.badge).scaleEffect(1.4)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var bottomBar: some View {
        HStack(spacing: 36) {
            Button { Task { await shareCurrent() } } label: { Image(systemName: "square.and.arrow.up") }
                .accessibilityLabel("Share")
            Button { showInfo = true } label: { Image(systemName: "info.circle") }
                .accessibilityLabel("Info")
            if let current, current.isCloudOnly, current.item?.isViewableFromCloud == true {
                Button { Task { await saveCurrent() } } label: { Image(systemName: "square.and.arrow.down") }
                    .accessibilityLabel("Save to Photos")
            }
            if current?.item?.status == .backedUp {
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                    .accessibilityLabel("Delete from cloud")
            }
        }
        .font(.title3)
        .foregroundStyle(.white)
        .padding(.vertical, 12)
        .padding(.horizontal, 28)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 24)
    }

    /// Fetches the first few MB of adjacent cloud videos so swiping to them starts playback instantly.
    private func prefetchNeighbours(of id: String?) {
        guard let id, let i = entries.firstIndex(where: { $0.id == id }) else { return }
        for j in [i - 1, i + 1] where entries.indices.contains(j) {
            if let item = entries[j].item, entries[j].isCloudOnly, item.kind == .video, item.isViewableFromCloud {
                AppEnvironment.shared.reader.prefetch(item)
            }
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
            if current?.isCloudOnly == true { dismiss() }
        } catch {
            message = GalleryAlert(title: "Couldn't delete", message: error.localizedDescription)
        }
    }
}

/// Loads and shows one item: zoomable photo, Live Photo or video, from the phone or from Telegram.
struct ViewerPage: View {
    let entry: GalleryEntry
    let isCurrent: Bool
    @Binding var zoomed: Bool

    enum Content {
        case loading(UIImage?)
        case image(UIImage)
        case live(PHLivePhoto)
        case video(AVPlayer)
        case unavailable(String, UIImage?)
    }

    @State private var content: Content = .loading(nil)
    /// Keeps the resource loader alive while a cloud video plays.
    @State private var stream: StreamingAsset?

    var body: some View {
        ZStack {
            switch content {
            case .loading(let placeholder):
                if let placeholder { Image(uiImage: placeholder).resizable().scaledToFit().blur(radius: 2) }
                ProgressView().tint(.white)
            case .image(let image):
                ZoomableImageView(image: image, zoomed: $zoomed)
            case .live(let live):
                LivePhotoView(livePhoto: live)
            case .video(let player):
                PlayerView(player: player)
                    .onChange(of: isCurrent) { _, now in if !now { player.pause() } }
                    .onDisappear { player.pause() }
            case .unavailable(let reason, let placeholder):
                VStack(spacing: 16) {
                    if let placeholder { Image(uiImage: placeholder).resizable().scaledToFit().frame(maxHeight: 280) }
                    Label(reason, systemImage: "icloud.slash").foregroundStyle(.white).multilineTextAlignment(.center).padding()
                }
            }
        }
        .task(id: entry.id) { await load() }
    }

    private func load() async {
        let env = AppEnvironment.shared
        let screen = await MainActor.run { UIScreen.main.bounds.size }
        let target = CGSize(width: screen.width * 3, height: screen.height * 3)

        if let asset = entry.asset {
            content = .loading(await env.photos.image(for: asset, targetSize: CGSize(width: 400, height: 400), mode: .fastFormat))
            if asset.mediaType == .video {
                if let item = await Self.playerItem(for: asset) { content = .video(AVPlayer(playerItem: item)) }
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
        content = .loading(thumb)
        guard item.isViewableFromCloud else {
            content = .unavailable("This item isn't fully in your Telegram library yet.", thumb)
            return
        }
        do {
            switch item.kind {
            case .video:
                // Stream byte ranges straight from Telegram: no full download needed.
                let s = StreamingAsset(item: item, role: "o", reader: env.reader)
                stream = s
                let playerItem = AVPlayerItem(asset: s.asset)
                playerItem.preferredForwardBufferDuration = 4
                content = .video(AVPlayer(playerItem: playerItem))
            case .livePhoto:
                let url = try await env.media.original(for: item)
                if let image = await Self.decode(url, maxPixel: max(target.width, target.height)) { content = .image(image) }
                if let video = try? await env.media.original(for: item, role: .pairedVideo),
                   let live = await Self.livePhoto(urls: [url, video]) {
                    content = .live(live)
                }
            case .photo:
                // Progressive: thumbnail → screen-size decode → full detail when zooming.
                let url = try await env.media.original(for: item)
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

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        view.livePhoto = livePhoto
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Live Photo. Touch and hold to play."
        let badge = UIButton(type: .system)
        badge.setImage(UIImage(systemName: "livephoto.play"), for: .normal)
        badge.setTitle(" LIVE", for: .normal)
        badge.tintColor = .white
        badge.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        badge.layer.cornerRadius = 12
        badge.contentEdgeInsets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.addAction(UIAction { [weak view] _ in view?.startPlayback(with: .full) }, for: .touchUpInside)
        view.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            badge.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60)
        ])
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        if view.livePhoto !== livePhoto { view.livePhoto = livePhoto }
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

/// AVPlayerViewController: native controls, scrubbing, playback speed, Picture in Picture and AirPlay.
struct PlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        let vc = AVPlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.entersFullScreenWhenPlaybackBegins = false
        vc.videoGravity = .resizeAspect
        if #available(iOS 16.0, *) { vc.speeds = [0.5, 1, 1.25, 1.5, 2].map { AVPlaybackSpeed(rate: $0, localizedName: "\($0)×") } }
        vc.view.backgroundColor = .black
        player.allowsExternalPlayback = true
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player { vc.player = player }
    }
}
