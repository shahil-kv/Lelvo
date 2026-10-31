---
name: verify
description: Run Lelvo's checks before calling a change done - core unit tests, iOS and Mac builds with the no-new-warnings check. Use after any code change in Swift, project.yml or Config.
---

Run in order and stop at the first failure. Keep logs in `build/`, never paste a whole log.

1. Core tests (skip only if nothing under `Packages/` or logic in `Shared/Services` changed):
   `Scripts/build.sh test > build/test.log 2>&1; tail -15 build/test.log`
2. iOS: `Scripts/build.sh ios > build/ios.log 2>&1; grep -E ' error:' build/ios.log | head -20; Scripts/check-warnings.sh build/ios.log`
3. Mac: `Scripts/build.sh mac > build/mac.log 2>&1; grep -E ' error:' build/mac.log | head -20; Scripts/check-warnings.sh build/mac.log`
4. UI change only: `Scripts/build.sh uitest > build/uitest.log 2>&1; tail -30 build/uitest.log`

Both builds are required when anything in `Shared/` changed. A first build downloads TDLib (about 350 MB) and can
take 10+ minutes; run it in the background rather than waiting on a short timeout.

Report what ran and the result of each step, with the failing lines if any. Don't say "done" with a step skipped
unless you say which one and why.
