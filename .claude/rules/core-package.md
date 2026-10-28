---
paths:
  - "Packages/MemvoCore/**"
---

# MemvoCore

- No UIKit, AppKit, SwiftUI or PhotoKit here. The package must build and test with plain `swift test`.
- Every logic change comes with a test in `Packages/MemvoCore/Tests/MemvoCoreTests/`. Add it to the suite file that
  already covers the area (for example `FormatTests`, `LibraryStoreTests`) before making a new file.
- Run one suite while working: `cd Packages/MemvoCore && swift test --filter <SuiteName>`; the full
  `Scripts/build.sh test` before you finish.
- Tests use made-up data only: no real phone numbers, keys, file ids or photos.
