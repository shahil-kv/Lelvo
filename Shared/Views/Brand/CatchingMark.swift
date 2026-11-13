import SwiftUI

/// The Lelvo mark as the backup's status: photos fly into its cloud, the cloud gives a little as it catches each one,
/// and a check appears when everything is safe. Decorative motion only runs while the screen is open and visible,
/// at most 4 flights a second, and never in Low Power Mode or with Reduce Motion; the numbers next to it carry the
/// same information.
struct CatchingMark: View {
    enum Status: Equatable { case working, complete, attention, idle }

    let status: Status
    var width: CGFloat = 96
    /// Photos to send in together, for example the ones just removed from the phone. A new id plays it once.
    var burst: Burst?

    struct Burst: Equatable {
        let id = UUID()
        let images: [PlatformImage]
        static func == (a: Burst, b: Burst) -> Bool { a.id == b.id }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var flights: [Flight] = []
    @State private var catches = 0
    @State private var lastFlight = Date.distantPast
    @State private var visible = false

    struct Flight: Identifiable {
        let id = UUID()
        let image: PlatformImage
        let from: CGPoint
    }

    private var height: CGFloat { width / LelvoMark.aspectRatio }
    private var target: CGPoint { CGPoint(x: LelvoMark.cloudCenter.x * width, y: LelvoMark.cloudCenter.y * height) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            LelvoMark(part: .camel).fill(Brand.gradient)
            LelvoMark(part: .cloud).fill(Brand.gradient)
                .keyframeAnimator(initialValue: Squash(), trigger: catches) { view, s in
                    view.scaleEffect(x: s.x, y: s.y, anchor: .bottom)
                } keyframes: { _ in
                    KeyframeTrack(\.x) {
                        CubicKeyframe(1.07, duration: 0.09); SpringKeyframe(1, duration: 0.3, spring: .bouncy)
                    }
                    KeyframeTrack(\.y) {
                        CubicKeyframe(0.9, duration: 0.09); SpringKeyframe(1, duration: 0.3, spring: .bouncy)
                    }
                }
            ForEach(flights) { flight in
                FlightView(image: flight.image, from: flight.from, to: target)
            }
            if status == .complete {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: width * 0.24, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
                    .background(Circle().fill(.background).padding(2))
                    .offset(x: width * 0.84, y: height * 0.62)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .frame(width: width, height: height)
        .opacity(status == .idle ? 0.6 : 1)
        .motion(Motion.emphasis, value: status)
        .onAppear { visible = true }
        .onDisappear { visible = false; flights.removeAll() }
        .onReceive(BackupActivity.shared.$landed.dropFirst()) { landed in
            if let landed { launch(landed.localIdentifier) }
        }
        .onChange(of: burst) { _, burst in if let burst { play(burst) } }
        .accessibilityHidden(true)
    }

    private func launch(_ localIdentifier: String) {
        let now = Date()
        guard visible, scenePhase == .active, Motion.decorative(reduceMotion: reduceMotion),
              now.timeIntervalSince(lastFlight) >= 0.25, flights.count < 3 else { return }
        lastFlight = now
        let side = CGFloat.random(in: -0.35...0.35)
        let from = CGPoint(x: width * (0.5 + side), y: height + 70)
        Task {
            // PhotoKit off the main actor: a fetch and a small image request.
            let image = await Task.detached(priority: .utility) { () -> PlatformImage? in
                let photos = AppEnvironment.shared.photos
                guard let asset = photos.asset(localIdentifier: localIdentifier) else { return nil }
                return await photos.image(for: asset, targetSize: CGSize(width: 120, height: 120), mode: .fastFormat)
            }.value
            // Checked again after the image load: other landings may have filled the slots while it was loading.
            guard let image, visible, flights.count < 3 else { return }
            let flight = Flight(image: image, from: from)
            flights.append(flight)
            try? await Task.sleep(for: .milliseconds(520))
            catches += 1
            Haptics.land()
            try? await Task.sleep(for: .milliseconds(120))
            flights.removeAll { $0.id == flight.id }
        }
    }
}

extension CatchingMark {
    /// Up to 8 photos from a row below the mark, a beat apart, each caught by the cloud.
    private func play(_ burst: Burst) {
        guard visible, Motion.decorative(reduceMotion: reduceMotion) else { return }
        let images = Array(burst.images.prefix(8))
        Task {
            for (i, image) in images.enumerated() {
                let spread = images.count > 1 ? CGFloat(i) / CGFloat(images.count - 1) - 0.5 : 0
                let flight = Flight(image: image, from: CGPoint(x: width * (0.5 + spread * 1.6), y: height + 84))
                flights.append(flight)
                Task {
                    try? await Task.sleep(for: .milliseconds(520))
                    catches += 1
                    if i.isMultiple(of: 3) { Haptics.land() }
                    try? await Task.sleep(for: .milliseconds(120))
                    flights.removeAll { $0.id == flight.id }
                }
                try? await Task.sleep(for: .milliseconds(85))
            }
        }
    }
}

private struct Squash {
    var x: CGFloat = 1
    var y: CGFloat = 1
}

/// One photo on its way into the cloud: lifts, arcs in, shrinks and fades as it goes in.
private struct FlightView: View {
    let image: PlatformImage
    let from: CGPoint
    let to: CGPoint
    @State private var go = false

    var body: some View {
        Image(platformImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
            .keyframeAnimator(initialValue: Values(position: from), trigger: go) { view, v in
                view.scaleEffect(v.scale).opacity(v.opacity).position(v.position)
            } keyframes: { _ in
                let mid = CGPoint(x: (from.x + to.x) / 2, y: min(from.y, to.y) - 26)
                KeyframeTrack(\.position) {
                    CubicKeyframe(mid, duration: 0.3)
                    CubicKeyframe(to, duration: 0.22)
                }
                KeyframeTrack(\.scale) {
                    CubicKeyframe(1.05, duration: 0.1)
                    CubicKeyframe(0.55, duration: 0.24)
                    CubicKeyframe(0.12, duration: 0.18)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(1, duration: 0.4)
                    LinearKeyframe(0, duration: 0.12)
                }
            }
            .onAppear { go = true }
            .allowsHitTesting(false)
    }

    struct Values {
        var position: CGPoint
        var scale: CGFloat = 1
        var opacity: Double = 0.95
    }
}
