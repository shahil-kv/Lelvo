# Motion reference

Deployment targets: iOS 17, macOS 15. Anything newer needs `if #available`.

## Tokens

One place for timing, so every screen moves the same way. Put them in `Shared/Support/Motion.swift`.

| Token | Value | Use |
|---|---|---|
| `Motion.tap` | `.snappy(duration: 0.18)` | Press states, toggles, small changes |
| `Motion.standard` | `.smooth(duration: 0.32)` | Sheets, cards, state swaps |
| `Motion.emphasis` | `.bouncy(duration: 0.45, extraBounce: 0.08)` | Something arrives: a badge, the cloud catching a photo |
| `Motion.hero` | `.spring(duration: 0.6, bounce: 0.15)` | Zoom-through, onboarding moments |
| Stagger | 0.03 to 0.06 s per item, at most 8 items | Lists and grids that appear together |

```swift
enum Motion {
    static let tap = Animation.snappy(duration: 0.18)
    static let standard = Animation.smooth(duration: 0.32)
    static let emphasis = Animation.bouncy(duration: 0.45, extraBounce: 0.08)
    static let hero = Animation.spring(duration: 0.6, bounce: 0.15)

    /// Reduce Motion swaps movement for a short fade; callers pass the environment value.
    static func adaptive(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.2) : animation
    }
}
```

## Haptic map

Use the existing `Haptics` enum in `Shared/Support/Platform.swift` (no-ops on Mac) or `.sensoryFeedback` in SwiftUI.

| Moment | Haptic |
|---|---|
| Backup finished, space freed, sign-in done, passphrase set | `.success` |
| Action failed, wrong code | `.error` |
| A photo lands in the cloud (throttled, at most 1 per 250 ms) | `.impact(weight: .light, intensity: 0.5)` |
| Picker, segmented control, filter chip | `.selection` |
| Long-press menu opens, drag picks up | `.impact(weight: .medium)` |
| Scroll, every tap, timers, background events | none |

```swift
.sensoryFeedback(.success, trigger: backupState == .done)   // fires on change, not on every render
```

## SwiftUI patterns

- Counters: `Text(bytes, format: .byteCount(style: .file)).contentTransition(.numericText(value: Double(bytes)))`
  inside `withAnimation(Motion.standard)`.
- Symbols: `.symbolEffect(.bounce, value: trigger)` for a one-off; `.symbolEffect(.pulse)` only while waiting.
- Sequences: `keyframeAnimator` for multi-step motion (launch, cloud squash); `PhaseAnimator` for loops that end.
- Thumbnail to viewer: iOS 18 `.navigationTransition(.zoom(sourceID:in:))` with `.matchedTransitionSource`;
  iOS 17 falls back to the current transition.
- Scroll effects: `.scrollTransition` and `.visualEffect` read geometry without re-running the view body.
- Flights (photo into cloud): an overlay layer above the screen, driven by events from the model. Copy the cached
  thumbnail, animate position, scale and opacity, remove on completion. The grid itself never re-lays out.

## Performance rules

- Animate `offset`, `scaleEffect`, `rotationEffect`, `opacity`. Avoid animating `frame`, padding, fonts or
  `blur` on more than a few views.
- `.drawingGroup()` only for many small vector shapes on screen at once (the launch mark); never on scroll content.
- Event-driven animation is throttled: a queue that starts at most 4 flights per second and only while
  `scenePhase == .active` and the view is visible. Extra events update counts only.
- Thumbnails come from the existing cache, decoded off the main actor. No PhotoKit fetch to start an animation.
- `ProcessInfo.processInfo.isLowPowerModeEnabled`: skip decorative flights, keep state changes.
- Check: Instruments → Animation Hitches on a ProMotion device; `-autoScrollTest` for grids.

## Website (lelvo.app)

Plain CSS and JS, no frameworks (see `.claude/rules/website.md`).

- Animate `transform` and `opacity`; ease `cubic-bezier(0.22, 1, 0.36, 1)` (the `ease` token).
- Every animation sits inside `@media (prefers-reduced-motion: no-preference)`.
- Reveal on scroll with `IntersectionObserver`, once per element; nothing above the fold waits on JS.
- Page-to-page: `@view-transition { navigation: auto; }` where supported, nothing otherwise.
