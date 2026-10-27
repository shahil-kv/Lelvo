# Contributing to Memvo

Thanks for helping. Memvo holds people's only copies of their photos, so the bar for changes is high, and the
process below keeps everyone's time well spent. Please read all of it before you write code; pull requests are held
to it.

## The short version

1. **Open or find an issue** for the bug or feature. Use the forms; blank issues are off.
2. **Wait for the `approved` label.** That label, added by a maintainer, is the only green light. A reply, a reaction
   or silence is not.
3. **Open a pull request** that says `Closes #<issue number>`, fill in the template, and sign the
   [CLA](CLA.md) when the bot asks (once).
4. **CI must be green** and a maintainer reviews. An automated CodeRabbit review may comment first.

A pull request whose linked issue isn't `approved` is **closed automatically, unreviewed**. It reopens on its own once
the issue is approved. Docs-only changes (`*.md`, `docs/`, `website/`) skip this and need no approval.

## Before you open an issue

- Search [open and closed issues](https://github.com/shahil-kv/Memvo/issues?q=is%3Aissue).
- Read [docs/FAQ.md](docs/FAQ.md) and [docs/not-planned.md](docs/not-planned.md). Requests on the not-planned list are
  closed.
- Problems with your Telegram account itself (frozen, banned, deleted, codes not arriving) are Telegram's, not a bug.
- Security problems go to [SECURITY.md](SECURITY.md), never to an issue.

## Labels

| Label | Meaning |
|---|---|
| `bug`, `enhancement`, `question`, `documentation` | What the issue is about |
| `platform: ios`, `platform: macos`, `area: backup`, `area: telegram`, `area: ui` | Where it is |
| `priority: high`, `priority: medium`, `priority: low` | How soon it should be done (set by a maintainer) |
| `performance` | Speed, memory, battery or disk use |
| `needs-info` | Waiting for the reporter; closed after 14 days without a reply |
| `approved` | Agreed: a pull request may link it |
| `good first issue`, `help wanted` | Approved and a good place to start |
| `not planned`, `duplicate` | Closed, with the reason |

## Writing the change

- **Set up** with [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md): XcodeGen, Telegram app keys, tests.
- **Follow [AGENTS.md](AGENTS.md)**, the project's coding rules (for people and coding assistants alike). In short:
  - Match the surrounding code: naming, structure, comment density.
  - One focused change per pull request. No drive-by reformatting or renames.
  - Never block the main thread with PhotoKit, SQLite, file or network work.
  - Data safety first: nothing may delete photos, or count something as backed up, unless it's verified.
  - Keep the storage format compatible. Changes to [docs/CLOUD_FORMAT.md](docs/CLOUD_FORMAT.md) need their own issue.
  - Stay within the [Telegram API terms](https://core.telegram.org/api/terms): no tricks, honour slow-down requests.
  - No new dependencies without an approved issue that discusses them.
  - User-facing text: short, plain sentences, the way Apple's own apps talk.
- **Shared code** (`Shared/`) builds for both apps. Build both before pushing:
  `Scripts/build.sh ios && Scripts/build.sh mac`.
- **Tests**: add or update unit tests in `Packages/MemvoCore` for logic changes, and run
  `Scripts/build.sh test`. UI changes need a check on a real device or simulator.
- **No warnings.** CI fails on new compiler warnings in our code.

## The pull request

- Title: what changes, in plain words ("Backup: retry uploads after the network comes back").
- Fill in every section of the template. For anything visible, attach a **before and after** screenshot or recording.
- Say what you tested, on which devices and OS versions.
- Keep commits tidy; the maintainer squashes when merging.
- If you used an AI coding assistant, that's fine: you are still the author and responsible for every line, so review
  it as your own work.

## Translations, docs and design

Fixes to documentation and the FAQ are welcome without an issue. For translations and design (icons, screenshots),
open an issue first so the work is coordinated.

## The legal bit

- Contributions are accepted under the [Contributor License Agreement](CLA.md). It keeps the project GPL-3.0 and
  allows App Store releases. A bot asks you to sign it once, on your first pull request.
- Only submit work you have the right to submit. Don't paste code from other projects unless its license is
  compatible and you say where it came from.
- Everyone follows the [Code of Conduct](CODE_OF_CONDUCT.md).

Maintainers: the day-to-day process (triage, reviews, releases, connected services) is in [MAINTAINING.md](MAINTAINING.md).
