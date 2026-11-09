import SwiftUI

/// The end of setup, played once (issue #92): the person's own recent photos fall into a pile, the Lelvo mark appears
/// under them and pulls them into its cloud, then settles with "Your library is ready". Shown only after Telegram has
/// confirmed the first photo. The images are the thumbnails the screen already loaded, so it costs no extra work;
/// only transform and opacity move. With Reduce Motion or in Low Power Mode it shows the final state at once.
struct LibraryReadyView: View {
    let images: [PlatformImage]
    let detail: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dealt = 0
    @State private var markShown = false
    @State private var pulled = 0
    @State private var catches = 0
    @State private var settled = false

    private static let markWidth: CGFloat = 110
    private static let markRestY: CGFloat = 150
    private static let markScaleInPile: CGFloat = 0.5
    /// A loose pile in a 300 × 280 area around the centre: x, y, rotation, size.
    private static let spots: [(x: CGFloat, y: CGFloat, r: Double, s: CGFloat)] = [
        (-62, -150, -7, 0.85), (12, -162, 6, 0.8), (-14, -110, -3, 0.95), (-74, -62, 5, 1),
        (30, -76, -8, 1), (-30, -20, 3, 1.1), (48, -6, 9, 0.95), (-68, 32, -6, 0.95),
        (8, 40, 2, 1.15), (-36, 96, -9, 0.85), (46, 98, 7, 0.9),
    ]

    private var photos: [PlatformImage] { Array(images.prefix(Self.spots.count)) }
    /// Bottom of the pile first, as if the cloud pulls the nearest ones in.
    private var pullOrder: [Int] { photos.indices.sorted { Self.spots[$0].y > Self.spots[$1].y } }

    private var target: CGSize {
        let w = Self.markWidth * Self.markScaleInPile, h = w / LelvoMark.aspectRatio
        return CGSize(width: (LelvoMark.cloudCenter.x - 0.5) * w, height: Self.markRestY + (LelvoMark.cloudCenter.y - 0.5) * h)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Brand.violet.opacity(0.7), Brand.violet.opacity(0.15), .clear],
                                     center: .center, startRadius: 0, endRadius: 170))
                .frame(width: 340, height: 340)
                .offset(y: -30)
                .scaleEffect(settled ? 1 : 0.5)
                .opacity(settled ? 1 : 0)

            ForEach(photos.indices, id: \.self) { i in
                photo(i)
            }

            LelvoMark().fill(.white)
                .frame(width: Self.markWidth, height: Self.markWidth / LelvoMark.aspectRatio)
                .keyframeAnimator(initialValue: CGSize(width: 1, height: 1), trigger: catches) { view, s in
                    view.scaleEffect(x: s.width, y: s.height)
                } keyframes: { _ in
                    KeyframeTrack(\.width) { CubicKeyframe(1.1, duration: 0.08); SpringKeyframe(1, duration: 0.26, spring: .bouncy) }
                    KeyframeTrack(\.height) { CubicKeyframe(0.86, duration: 0.08); SpringKeyframe(1, duration: 0.26, spring: .bouncy) }
                }
                .scaleEffect(markShown ? (settled ? 1 : Self.markScaleInPile) : 0.01)
                .opacity(markShown ? 1 : 0)
                .offset(y: settled ? -30 : Self.markRestY)

            VStack(spacing: 10) {
                Text("Your library is ready").font(.system(size: 30, weight: .bold)).multilineTextAlignment(.center)
                Text(detail).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .offset(y: 110)
            .opacity(settled ? 1 : 0)
            .offset(y: settled ? 0 : 12)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 440)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your library is ready. \(detail)")
        .task { await run() }
    }

    private func photo(_ i: Int) -> some View {
        let spot = Self.spots[i]
        let isPulled = (pullOrder.firstIndex(of: i) ?? 0) < pulled
        return Image(platformImage: photos[i])
            .resizable()
            .scaledToFill()
            .frame(width: 70 * spot.s, height: 82 * spot.s)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.5), radius: 10, y: 6)
            .rotationEffect(.degrees(isPulled ? spot.r + (spot.x < 0 ? 100 : -100) : spot.r))
            .scaleEffect(isPulled ? 0.05 : 1)
            .opacity(i < dealt && !isPulled ? 1 : 0)
            .offset(x: isPulled ? target.width : spot.x, y: isPulled ? target.height : (i < dealt ? spot.y : spot.y - 320))
            .zIndex(Double(i))
    }

    private func run() async {
        guard Motion.decorative(reduceMotion: reduceMotion) else {
            dealt = photos.count; pulled = photos.count; markShown = true; settled = true
            return
        }
        for i in photos.indices {
            withAnimation(.spring(duration: 0.5, bounce: 0.28)) { dealt = i + 1 }
            try? await Task.sleep(for: .milliseconds(80))
        }
        try? await Task.sleep(for: .milliseconds(380))
        withAnimation(Motion.emphasis) { markShown = true }
        try? await Task.sleep(for: .milliseconds(420))
        for k in photos.indices {
            withAnimation(.timingCurve(0.55, 0, 0.75, 0.3, duration: 0.48)) { pulled = k + 1 }
            if k.isMultiple(of: 2) {
                Task {
                    try? await Task.sleep(for: .milliseconds(420))
                    catches += 1
                    if k.isMultiple(of: 4) { Haptics.land() }
                }
            }
            try? await Task.sleep(for: .milliseconds(75))
            if Task.isCancelled { return }
        }
        try? await Task.sleep(for: .milliseconds(500))
        withAnimation(.spring(duration: 0.7, bounce: 0.22)) { settled = true }
        Haptics.success()
    }
}
