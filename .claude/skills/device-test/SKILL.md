---
name: device-test
description: Install a Debug build on the owner's iPhone and read the app log to confirm a fix. Use when the owner asks to test on the phone, or before pushing a fix to backup, streaming or sign-in.
disable-model-invocation: true
---

Simulator and unit tests miss real bugs (stalls, TDLib timing). The app log on the phone is the evidence.

1. Team id: `DEVELOPMENT_TEAM` from `CLAUDE.local.md` or the environment. If neither has it, ask.
2. Build into the same `build/` folder so sign-in and data on the phone survive:
   `xcodebuild -project Memvo.xcodeproj -scheme Memvo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages DEVELOPMENT_TEAM=<id> -allowProvisioningUpdates build > build/device.log 2>&1; tail -5 build/device.log`
3. Find the phone: `xcrun devicectl list devices`
4. Install: `xcrun devicectl device install app --device <id> build/DerivedData/Build/Products/Debug-iphoneos/Memvo.app`
5. Don't launch or relaunch the app yourself. Ask the owner to open it and do concrete steps ("open a cloud video,
   seek to the middle, switch to mobile data").
6. Copy the log out of the app container (`Library/Application Support/Logs/memvo.log`) with
   `xcrun devicectl device copy from --device <id> --domain-type appDataContainer --domain-identifier <bundle id> --source "Library/Application Support/Logs/memvo.log" --destination build/devicelogs/memvo.log`
   (bundle id `com.shahil-kv.memvo`), then `grep` the relevant lines. Don't dump the whole log.
7. If the bug fails silently, add an `appLog` line for it so the next report shows it.

Report what the log showed, with the lines that prove the fix. Push only after the owner confirms.
