---
name: android-verify
description: Run the Android app's checks before calling an Android change done - core JVM tests, debug build with no new Kotlin warnings, and install on the emulator. Use after any change under android/.
---

Run from `android/`, stop at the first failure, keep logs in `../build/`, never paste a whole log.

1. Core tests: `./gradlew :core:test > ../build/android-test.log 2>&1; tail -15 ../build/android-test.log`
   On failure: `ls core/build/test-results/test/` and read the failing XML only.
2. Build: `./gradlew :app:assembleDebug > ../build/android.log 2>&1; grep -E '^e: |error:|What went wrong' -A4 ../build/android.log | head -30; grep -E '^w: ' ../build/android.log | head`
   No new `w:` lines.
3. UI or device behaviour changed: boot `Pixel_9` if no device (`~/Library/Android/sdk/emulator/emulator -avd Pixel_9 -no-snapshot-save &`),
   `adb install -r app/build/outputs/apk/debug/app-debug.apk`, launch, screenshot with `adb exec-out screencap -p`, look at it.
4. Parity: say which iOS files you compared against and what edge cases you checked (`.claude/rules/android.md`).

Report what ran and each result. Never install on the owner's phone without asking.
