# Working on Lelvo

House rules for everyone who changes the code: contributors, maintainers and coding assistants. The automated
review (CodeRabbit) checks pull requests against this file.

## What the app is

Native iOS and macOS apps that back up a user's Photos library, as original files, to a private channel in the user's
own Telegram account through TDLib, and show phone and cloud items in one timeline. No servers. The channel is the
source of truth; the local SQLite index is a cache rebuilt by scanning it. Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
and [docs/CLOUD_FORMAT.md](docs/CLOUD_FORMAT.md) before changing anything in `Shared/Services` or `Packages/`.

## Non-negotiables

1. **Never lose a photo.** Nothing deletes from the device unless the user chose it and the system confirms. Nothing
   counts as backed up until Telegram has confirmed every part with the expected size. When in doubt, keep data.
2. **Keep the storage format compatible.** Caption JSON, encryption (CGFE), split parts and the library header are a
   public contract with test vectors (`docs/test-vectors/format1.json`). Changing them needs an approved issue, a format
   version bump and migration.
3. **Respect Telegram.** Honour `FLOOD_WAIT` exactly, keep at most two parallel uploads and the pacing between them,
   only act on the user's own library channel, never act without the user's request. Follow the
   [Telegram API terms](https://core.telegram.org/api/terms).
4. **No secrets or personal data in logs, UI text, tests or commits.** Phone numbers, `api_hash`, login codes,
   passwords, passphrases, keys and file ids never appear. Log through `AppLog`, which redacts.
5. **Nothing heavy on the main thread.** PhotoKit fetches, SQLite, hashing, file IO and network run off the main actor;
   UI updates hop back with `MainActor`.
6. **Both platforms build.** `Shared/` compiles for iOS and macOS. Use `Shared/Support/Platform.swift` helpers; put
   platform-only code in `iOS/` or `macOS/`.
7. **No new dependencies** without an approved issue.

## Style

- Match the surrounding code: naming, file layout, access control, comment density. Read the file before changing it.
- Comments explain *why* (a TDLib quirk, a platform limit, an Apple bug), not what the next line does.
- Small, focused changes. No unrelated reformatting, renames or "while I was here" refactors.
- Errors shown to users are `LocalizedError`s with one or two plain sentences that say what to do next.
- UI follows Apple's own apps (Photos, Settings): system controls, solid grouped forms, Dynamic Type, VoiceOver
  labels, dark and light mode.
- User-facing text: short sentences, plain words, no jargon, no exclamation marks. Say "your Telegram library".
- Test hooks (launch arguments) are compiled only in Debug (`#if DEBUG`).

## Before you push

```sh
Scripts/build.sh test          # core unit tests
Scripts/build.sh ios           # no new warnings
Scripts/build.sh mac
```

Logic changes come with unit tests in `Packages/LelvoCore`. UI changes are checked on a device or simulator,
with before and after screenshots in the pull request.

## Commits and pull requests

- Commit subject: what changed, in plain words, optionally prefixed by the area (`ios:`, `mac:`, `backup:`, `docs:`).
- A pull request links an issue labelled `approved` (`Closes #123`), except docs-only changes.
- If a coding assistant helped, the human who opens the pull request is the author and reviews every line.
