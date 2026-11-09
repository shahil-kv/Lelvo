import SwiftUI

/// The opening on a cold launch (issue #92). Its first frame is the iOS launch screen (the white mark on
/// `Brand.launch`), so there's no jump. The mark breathes in once, then you zoom through it into the app, which has
/// been loading underneath the whole time. Under a second, a tap skips it, and Reduce Motion makes it a fade.
/// Resuming from the background never shows it: it lives for one process launch only.
struct LaunchOverlay: View {
    /// Width of the mark on the launch screen (`LaunchMark.imageset` is drawn at this width).
    static let markWidth: CGFloat = 124

    let onFinish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scale: CGFloat = 1
    @State private var solid: Double = 1
    @State private var curtain: Double = 1
    @State private var finished = false

    var body: some View {
        ZStack {
            // A shape, not a scaled view, so the edges stay sharp at 60×.
            ZoomedMark(scale: scale, curtain: true).fill(Brand.launch, style: FillStyle(eoFill: true))
            ZoomedMark(scale: scale, curtain: false).fill(.white).opacity(solid)
        }
        .opacity(curtain)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { finish(fast: true) }
        .accessibilityHidden(true)
        .task { await run() }
    }

    private func run() async {
        if reduceMotion {
            try? await Task.sleep(for: .milliseconds(150))
            return finish(fast: false)
        }
        try? await Task.sleep(for: .milliseconds(160))
        withAnimation(.easeInOut(duration: 0.15)) { scale = 0.91 }
        try? await Task.sleep(for: .milliseconds(150))
        // Accelerating: slow enough to read the mark, then through it.
        withAnimation(.timingCurve(0.6, 0, 0.84, 0.25, duration: 0.42)) { scale = 64 }
        withAnimation(.easeOut(duration: 0.14)) { solid = 0 }
        try? await Task.sleep(for: .milliseconds(420))
        finish(fast: false)
    }

    private func finish(fast: Bool) {
        guard !finished else { return }
        finished = true
        withAnimation(.easeOut(duration: fast || reduceMotion ? 0.2 : 0.08)) { curtain = 0 } completion: { onFinish() }
    }
}

/// The mark at the launch-screen size, centred on the screen and scaled about the camel's neck. With `curtain`, it's a
/// full-screen rectangle with the mark cut out (fill it even-odd).
private struct ZoomedMark: Shape {
    var scale: CGFloat
    let curtain: Bool

    var animatableData: CGFloat {
        get { scale }
        set { scale = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let w = LaunchOverlay.markWidth, h = w / LelvoMark.aspectRatio
        let base = CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
        let anchor = CGPoint(x: base.minX + LelvoMark.zoomAnchor.x * w, y: base.minY + LelvoMark.zoomAnchor.y * h)
        let zoom = CGAffineTransform(translationX: anchor.x, y: anchor.y).scaledBy(x: scale, y: scale).translatedBy(x: -anchor.x, y: -anchor.y)
        var path = curtain ? Path(rect.insetBy(dx: -1, dy: -1)) : Path()
        path.addPath(LelvoMark().path(in: base), transform: zoom)
        return path
    }
}

extension View {
    /// Plays `LaunchOverlay` over this view while `isLaunching` is true, easing the content in from slightly larger as
    /// the zoom opens onto it.
    func launchOverlay(isLaunching: Binding<Bool>) -> some View {
        modifier(LaunchOverlayModifier(isLaunching: isLaunching))
    }
}

private struct LaunchOverlayModifier: ViewModifier {
    @Binding var isLaunching: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isLaunching && !settled && !reduceMotion ? 1.08 : 1)
            .overlay {
                if isLaunching {
                    LaunchOverlay { isLaunching = false }
                        .onAppear {
                            withAnimation(.smooth(duration: 0.55).delay(0.32)) { settled = true }
                        }
                }
            }
    }
}
