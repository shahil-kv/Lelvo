@AGENTS.md

# Notes for Claude Code

Only what the code can't tell you. Area rules load from `.claude/rules/` when you touch those files; procedures live
in `.claude/skills/`. Personal settings go in `CLAUDE.local.md` (ignored by git).

## Check your work

- Core tests, seconds: `Scripts/build.sh test`. One suite: `cd Packages/MemvoCore && swift test --filter FormatTests`
- iOS build: `Scripts/build.sh ios > build/ios.log 2>&1; tail -5 build/ios.log; Scripts/check-warnings.sh build/ios.log`
- Mac build: same with `mac` and `build/mac.log`
- UI tests are slow (minutes): `Scripts/build.sh uitest`, only for UI changes
- Never print a full `xcodebuild` log into the conversation. Redirect to `build/*.log`, then `tail` or
  `grep -E 'error:|warning:'`.

## Where to look first

| Task | Start in |
|---|---|
| Upload, retry, job states | `Shared/Services/BackupEngine.swift`, `Packages/MemvoCore/Sources/MemvoCore/Backup/JobQueue.swift` |
| TDLib calls, sign-in, ranged reads | `Shared/Services/Telegram/TDService.swift` |
| Channel, header, restore scan | `Shared/Services/Telegram/LibraryService.swift`, `.../Format/LibraryIndexer.swift` |
| Caption JSON, roles, parts | `Packages/MemvoCore/Sources/MemvoCore/Format/`, `docs/CLOUD_FORMAT.md` |
| Encryption | `Packages/MemvoCore/Sources/MemvoCore/Crypto/FileCrypto.swift` |
| SQLite index | `Packages/MemvoCore/Sources/MemvoCore/Index/LibraryStore.swift` |
| Video streaming | `Shared/Services/Telegram/MediaReader.swift`, `StreamingAsset.swift`, `Shared/Views/Gallery/CloudVideo.swift` |
| Deleting from the phone | `Shared/Services/FreeUpSpaceService.swift` |
| Gallery state | `Shared/Views/Gallery/GalleryModel.swift`; grids are `iOS/Views/Gallery/NativePhotoGrid.swift`, `macOS/Views/MacPhotoGrid.swift` |
| Services wiring | `Shared/App/AppEnvironment.swift` |
| Targets, Info.plist keys | `project.yml` |

## Save context

- Large files (`BackupEngine`, `OnboardingView`, `ViewerView`, `TDService`: 1,000+ lines each): grep for the symbol,
  then read only that range.
- Read `docs/ARCHITECTURE.md` or `docs/CLOUD_FORMAT.md` only for the section you need, not whole.
- `docs/PROGRESS.md` is the handoff note when resuming bigger work.
- Hand wide searches ("every caller of X across both apps") to the Explore agent so only the answer comes back.
- Start a fresh session (`/clear`) between unrelated tasks. Before `/compact`, say what to keep.

## Gotchas

- `Memvo.xcodeproj` is generated from `project.yml` and ignored. Edit `project.yml`; `Scripts/build.sh` regenerates.
- `Packages/MemvoCore/Sources/MemvoCore/BotAPI/` is the old v1 Bot API client. The apps use TDLib; don't extend it.
- Stale `CloudGalleryCore` folders under `.build/` are from the old name. Ignore them.
- `marketing/` is excluded through `.git/info/exclude`. Never commit it.
- Don't relaunch the app on the owner's iPhone without asking. They may be using it.
- After `docs/CHANGELOG.md` or `PRIVACY.md` changes, `website/*.html` must be regenerated in the same commit. A hook
  runs `python3 Scripts/website-pages.py` for you; check its output.
