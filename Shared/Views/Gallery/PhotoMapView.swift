import SwiftUI
import MapKit
import MemvoCore

/// Every photo and video with a location (phone and cloud-only) on a map, like Photos' Places. MapKit clusters the
/// photos itself (`MKClusterAnnotation`), as Apple Photos does, so panning and zooming stay smooth with thousands of
/// them; each cluster shows its newest photo and a count. Tapping one opens its photos in a grid (`destination`).
/// Only Apple's map tiles are fetched; the photos stay on the device.
struct PhotoMapView<Destination: View>: View {
    @EnvironmentObject private var gallery: GalleryModel
    let destination: (GalleryFilter) -> Destination

    @State private var pins: [PhotoPin] = []
    @State private var loaded = false
    @State private var chosen: ChosenPhotos?

    struct ChosenPhotos: Hashable, Identifiable {
        let ids: [String]
        var id: Int { ids.hashValue }
    }

    var body: some View {
        PhotoMapRepresentable(pins: pins) { ids in chosen = ChosenPhotos(ids: ids) }
            .ignoresSafeArea(edges: .bottom)
            .overlay {
                if loaded && pins.isEmpty {
                    EmptyStateView(systemImage: "map", title: "No Places", message: "Photos and videos with a location show here.")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                        .padding(32)
                } else if !loaded {
                    ProgressView()
                }
            }
            .navigationTitle("Map")
            .navigationDestination(item: $chosen) { c in
                destination(.matching(title: "\(c.ids.count) Item\(c.ids.count == 1 ? "" : "s")", ids: Set(c.ids)))
            }
            .task(id: gallery.revision) {
                let entries = gallery.entries
                pins = await Task.detached(priority: .userInitiated) { PhotoPin.pins(entries) }.value
                loaded = true
            }
    }
}

/// One photo on the map. A class because MapKit identifies annotations by object.
final class PhotoPin: NSObject, MKAnnotation {
    let entry: GalleryEntry
    let coordinate: CLLocationCoordinate2D
    var date: Date { entry.date ?? .distantPast }

    init(entry: GalleryEntry, coordinate: CLLocationCoordinate2D) {
        self.entry = entry
        self.coordinate = coordinate
    }

    nonisolated static func pins(_ entries: [GalleryEntry]) -> [PhotoPin] {
        entries.compactMap { e in
            let c: CLLocationCoordinate2D?
            if let loc = e.asset?.location {
                c = loc.coordinate
            } else if let item = e.item, let lat = item.latitude, let lon = item.longitude {
                c = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            } else {
                c = nil
            }
            // 0,0 is a missing location written as zeros, not a photo in the Gulf of Guinea.
            guard let c, CLLocationCoordinate2DIsValid(c), !(c.latitude == 0 && c.longitude == 0) else { return nil }
            return PhotoPin(entry: e, coordinate: c)
        }
    }
}

/// A square thumbnail with a white border and, for a cluster, a count badge.
final class PhotoPinView: MKAnnotationView {
    static let reuseId = "photo"
    static let clusterReuseId = "photos"
    private let imageLayer = CALayer()
    private let badge = CATextLayer()
    private var loading: Task<Void, Never>?
    private var shownId: String?

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 56, height: 56)
        centerOffset = CGPoint(x: 0, y: -28)
        imageLayer.frame = bounds
        imageLayer.cornerRadius = 10
        imageLayer.masksToBounds = true
        imageLayer.borderWidth = 2
        imageLayer.borderColor = CGColor(gray: 1, alpha: 1)
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.backgroundColor = CGColor(gray: 0.5, alpha: 0.4)
        badge.fontSize = 11
        badge.alignmentMode = .center
        badge.cornerRadius = 9
        badge.foregroundColor = CGColor(gray: 1, alpha: 1)
        badge.backgroundColor = PlatformColor.systemBlue.cgColor
        badge.isHidden = true
        #if os(iOS)
        layer.addSublayer(imageLayer)
        layer.addSublayer(badge)
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 3
        layer.shadowOffset = .zero
        badge.contentsScale = UIScreen.main.scale
        imageLayer.contentsScale = UIScreen.main.scale
        #else
        wantsLayer = true
        layer?.addSublayer(imageLayer)
        layer?.addSublayer(badge)
        badge.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        #endif
        collisionMode = .rectangle
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var annotation: MKAnnotation? {
        didSet { configure() }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        reset()
    }

    private func reset() {
        loading?.cancel()
        loading = nil
        shownId = nil
        imageLayer.contents = nil
    }

    private func configure() {
        let cover: PhotoPin?
        let count: Int
        if let cluster = annotation as? MKClusterAnnotation {
            let members = cluster.memberAnnotations.compactMap { $0 as? PhotoPin }
            cover = members.max { $0.date < $1.date }
            count = members.count
            displayPriority = .required
        } else {
            cover = annotation as? PhotoPin
            count = 1
            clusteringIdentifier = Self.clusterReuseId
            displayPriority = .defaultHigh
        }
        let text = count.formatted()
        let label = count > 1 ? "\(text) photos here" : "1 photo here"
        #if os(iOS)
        isAccessibilityElement = true
        accessibilityLabel = label
        accessibilityTraits = .button
        #else
        setAccessibilityElement(true)
        setAccessibilityLabel(label)
        setAccessibilityRole(.button)
        #endif
        badge.string = text
        badge.isHidden = count < 2
        let width = max(20, CGFloat(text.count) * 7 + 10)
        badge.frame = CGRect(x: bounds.width - width + 6, y: -6, width: width, height: 18)
        #if os(macOS)
        // AppKit layers start at the bottom left.
        badge.frame.origin.y = bounds.height - 12
        #endif
        guard let entry = cover?.entry, entry.id != shownId else { return }
        reset()
        shownId = entry.id
        if let cached = ThumbnailPipeline.shared.cached(entry)?.image { imageLayer.contents = Self.cg(cached); return }
        loading = Task { @MainActor [weak self] in
            for await image in ThumbnailPipeline.shared.images(for: entry, pixels: 168) {
                guard let self, self.shownId == entry.id else { return }
                self.imageLayer.contents = Self.cg(image)
            }
        }
    }

    private static func cg(_ image: PlatformImage) -> CGImage? {
        #if os(iOS)
        image.cgImage
        #else
        image.cgImageValue
        #endif
    }
}

#if os(iOS)
typealias PlatformColor = UIColor
private typealias MapRepresentable = UIViewRepresentable
#else
typealias PlatformColor = NSColor
private typealias MapRepresentable = NSViewRepresentable
#endif

private struct PhotoMapRepresentable: MapRepresentable {
    let pins: [PhotoPin]
    let onSelect: ([String]) -> Void

    final class Coordinator: NSObject, MKMapViewDelegate {
        var onSelect: ([String]) -> Void
        var shownIds: Set<String> = []
        var fitted = false
        init(onSelect: @escaping ([String]) -> Void) { self.onSelect = onSelect }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKClusterAnnotation {
                return mapView.dequeueReusableAnnotationView(withIdentifier: PhotoPinView.clusterReuseId, for: annotation)
            }
            guard annotation is PhotoPin else { return nil }
            return mapView.dequeueReusableAnnotationView(withIdentifier: PhotoPinView.reuseId, for: annotation)
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            let pins: [PhotoPin]
            if let cluster = view.annotation as? MKClusterAnnotation {
                pins = cluster.memberAnnotations.compactMap { $0 as? PhotoPin }
            } else if let pin = view.annotation as? PhotoPin {
                pins = [pin]
            } else {
                return
            }
            mapView.deselectAnnotation(view.annotation, animated: false)
            onSelect(pins.sorted { $0.date > $1.date }.map(\.entry.id))
        }

        /// Adds and removes only what changed, so a library refresh doesn't rebuild the map.
        func update(_ map: MKMapView, pins: [PhotoPin]) {
            let ids = Set(pins.map(\.entry.id))
            guard ids != shownIds else { return }
            let gone = map.annotations.compactMap { $0 as? PhotoPin }.filter { !ids.contains($0.entry.id) }
            let new = pins.filter { !shownIds.contains($0.entry.id) }
            map.removeAnnotations(gone)
            map.addAnnotations(new)
            shownIds = ids
            if !fitted, !pins.isEmpty {
                fitted = true
                map.showAnnotations(map.annotations, animated: false)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    private func makeMap(_ context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.pointOfInterestFilter = .excludingAll
        map.register(PhotoPinView.self, forAnnotationViewWithReuseIdentifier: PhotoPinView.reuseId)
        map.register(PhotoPinView.self, forAnnotationViewWithReuseIdentifier: PhotoPinView.clusterReuseId)
        context.coordinator.update(map, pins: pins)
        return map
    }

    #if os(iOS)
    func makeUIView(context: Context) -> MKMapView { makeMap(context) }
    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.update(map, pins: pins)
    }
    #else
    func makeNSView(context: Context) -> MKMapView { makeMap(context) }
    func updateNSView(_ map: MKMapView, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.update(map, pins: pins)
    }
    #endif
}
