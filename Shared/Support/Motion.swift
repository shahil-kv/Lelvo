import SwiftUI

/// Lelvo's animation timings, so every screen moves the same way (the `polishing-ui` skill). Springs, because they
/// pick up from wherever an interrupted animation was instead of jumping.
enum Motion {
    /// Press states, toggles, small swaps.
    static let tap = Animation.snappy(duration: 0.18)
    /// Sheets, cards, a value or state changing in place.
    static let standard = Animation.smooth(duration: 0.32)
    /// Something arriving: a badge, the cloud catching a photo, a check mark.
    static let emphasis = Animation.bouncy(duration: 0.45, extraBounce: 0.08)
    /// Rare, big moments: the launch zoom, the end of setup.
    static let hero = Animation.spring(duration: 0.6, bounce: 0.15)
    /// Leaving is quicker than arriving.
    static let exit = Animation.smooth(duration: 0.22)

    /// With Reduce Motion on, movement becomes a short fade that keeps the meaning.
    static func adaptive(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.2) : animation
    }

    /// Decorative motion (photos flying, piles, glows) is skipped in Low Power Mode and with Reduce Motion. State
    /// changes and numbers still animate.
    static func decorative(reduceMotion: Bool) -> Bool {
        !reduceMotion && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }
}

extension View {
    /// `.animation(_:value:)` with the Reduce Motion fallback.
    func motion<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(AdaptiveAnimation(animation: animation, value: value))
    }
}

private struct AdaptiveAnimation<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V

    func body(content: Content) -> some View {
        content.animation(Motion.adaptive(animation, reduceMotion: reduceMotion), value: value)
    }
}
