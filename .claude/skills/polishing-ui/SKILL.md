---
name: polishing-ui
description: Use when designing, building or reviewing any Lelvo screen, transition, animation, haptic, loading, empty, error or success state, or website interaction; when a screen feels flat, janky, slow, cheap or "not premium"; or when the owner asks for wow, polish, motion or haptics.
---

# Polishing UI: motion, haptics, states

## Core principle

Motion explains what just happened: where a photo went, what changed, what is safe now. It never decorates, never
makes the user wait, and never shows something the app has not confirmed. Premium comes from precision (timing,
springs, haptics, every state designed), not from more animation.

## Workflow (every screen or change)

1. **Audit** the screen against the checklist below. Write the gaps down before proposing anything.
2. **Preview first.** For any new motion, build an HTML preview artifact (phone frames, stock photos, replay, slow
   motion, light and dark) and get the owner's choice before Swift code. Fixed preferences: plan, preview, permission,
   then code.
3. **Build** with the tokens and patterns in `motion-reference.md` (springs, haptic map, SwiftUI APIs, web CSS).
4. **Measure:** Instruments "Animation Hitches" on a device, zero hitches over 33 ms; grids still pass
   `-autoScrollTest`; no new main-thread work. Then the `verify` skill.
5. **Check on a device** (ask before installing on the owner's iPhone) and record before and after screenshots or a
   screen recording for the PR.

## Screen checklist

| Area | Must have |
|---|---|
| States | Loading (skeleton or real content, never a bare spinner over 1 s), empty (what to do next), error (`LocalizedError`, one action), success, offline/paused (FLOOD_WAIT shown calmly) |
| Transitions | Push/zoom from the tapped thing, not from nowhere; dismiss returns to the same spot |
| Feedback | Every tap answers in under 100 ms: highlight, state change or haptic |
| Haptics | Only the moments in the haptic map; none on scroll or repeated taps |
| Numbers | Counts and sizes roll (`.numericText()`), never jump |
| Accessibility | Reduce Motion fallback (fade or nothing), Dynamic Type to AX5, VoiceOver labels, contrast in both modes |
| Performance | Transform and opacity only; nothing animates while backgrounded or in Low Power Mode beyond essentials |

## When not to animate

- Things seen many times a day: a resume from background, tab switches, every grid cell.
- Before the fact: no "backed up" or "freed" motion until `BackupEngine` or PhotoKit has confirmed it.
- When it would delay work: animations run beside loading, are interruptible, and a tap skips them.
- Big moments play once (end of setup, first full backup). Repeated moments stay under 400 ms.

## What the best apps do

| App | Lesson |
|---|---|
| Apple Photos | Zoom transitions from the tapped thumbnail; nothing else moves |
| Things 3 | One perfect completion animation + haptic instead of many |
| Revolut, Cash App | Rolling numbers make money changes feel real |
| Telegram | Every gesture is interruptible and follows the finger |
| Arc, Duolingo | Spend the "wow" on onboarding and wins, not on launch |
| Linear, Notion | No splash screen; speed is the brand |

## Common mistakes

| Mistake | Fix |
|---|---|
| Long launch animation on every open | Cold launch only, under 0.8 s, skippable, nothing on resume |
| `withAnimation` around a whole grid reload | Animate the one changed cell, or diff without animation |
| `.easeInOut(duration:)` everywhere | Springs from the token table; they retarget when interrupted |
| Haptic on every tap | Haptic map only; selection haptic for pickers |
| Animating `frame`, padding or blur on many views | Transform and opacity; blur only on a handful of short-lived layers |
| One animation per uploaded item at 50 items/s | Throttle to about 4 flights per second, count the rest |
| Motion that ignores Reduce Motion | `@Environment(\.accessibilityReduceMotion)` in every custom animation |
