---
paths:
  - "Packages/MemvoCore/Sources/MemvoCore/Format/**"
  - "Packages/MemvoCore/Sources/MemvoCore/Crypto/**"
  - "Shared/Services/Telegram/CloudUploader.swift"
  - "Shared/Services/Telegram/LibraryService.swift"
  - "docs/CLOUD_FORMAT.md"
  - "docs/test-vectors/**"
---

# Storage format

Files already in users' Telegram libraries must stay readable forever. Read the matching section of
`docs/CLOUD_FORMAT.md` before changing anything here.

- Additions are optional: a new caption field or a new role that old readers ignore. Never rename, remove or
  repurpose a field, a role or a byte in the CGFE header.
- Decoders must accept captions written by every earlier build, including fields they don't know.
- `docs/test-vectors/format1.json` is the contract. If a change makes an existing vector fail, the change is wrong,
  not the vector. Add new vectors; don't edit old ones.
- A change that needs a new format version or a migration needs an approved issue first. Stop and ask.
- Everything Photos knows about an item (original, edit render and adjustment data, RAW alternate, Live Photo video,
  albums, favourite, hidden, dates, place) is captured in both plain and encrypted libraries, even if no feature
  reads it yet. Nobody can re-upload after Free Up Space.
- Run `cd Packages/MemvoCore && swift test --filter FormatTests` and `--filter CryptoTests` after every change here.
