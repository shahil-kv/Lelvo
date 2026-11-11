# Android app: notes for Claude Code

Start sessions from `android/`. Plan, feature list and progress: [`../docs/ANDROID_PLAN.md`](../docs/ANDROID_PLAN.md).
Read only the step you're on and the section of `../docs/CLOUD_FORMAT.md` it needs.

## Every feature

Read the iOS code and its fix history first, then one or two proven open-source Android apps, then write the code,
then compare iOS and Android side by side for missed cases and bugs. Details and the reference list:
`../.claude/rules/android.md`.

## Rules that matter most

- The format contract is `../docs/CLOUD_FORMAT.md`; the Swift code is a reference, never the spec. If they disagree, stop and ask.
- End-to-end encrypted libraries only. Never write a plain resource; refuse unknown header versions.
- Captions get no Android-only fields.
- At most two uploads, honour `FLOOD_WAIT` exactly, only touch the user's own library channel.
- Nothing personal or secret in logs: phone numbers, codes, passwords, keys, file ids, `api_hash`.
- Main thread is for UI only: TDLib, Room, hashing, crypto and file IO run on `Dispatchers.IO`/`Default`.
- Debug builds use Telegram's test servers by default. Never test on the owner's real library.

## Check your work

- Core tests (seconds): `./gradlew :core:test > ../build/android-test.log 2>&1; tail -15 ../build/android-test.log`
- Debug build: `./gradlew :app:assembleDebug > ../build/android.log 2>&1; grep -E '^e: |What went wrong' -A4 ../build/android.log`
- Emulator: AVD `Pixel_9` (Android 16). Full checklist: the `android-verify` skill.

## Gotchas

- Compose BOM 2026.09 needs `compileSdk = 37`; targetSdk stays 36 until we test 37's behaviour changes.
- AGP 9 has Kotlin built in: Android modules don't apply `org.jetbrains.kotlin.android`.
- `local.properties` (SDK path, later Telegram `api_id`/`api_hash`) is ignored; never commit it.
