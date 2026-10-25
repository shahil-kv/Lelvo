# Maintaining Memvo

How the maintainer runs the project day to day: issues, pull requests, releases, and the tools that do the routine
work. Contributors don't need this; they read [CONTRIBUTING.md](CONTRIBUTING.md).

## A normal week

1. **GitHub notifications** (the GitHub app on your phone is easiest): new issues, pull requests, Discussions.
2. **Triage new issues** (below). Aim to label every new issue within a few days, even if the answer is "not now".
3. **Review pull requests** whose CI is green.
4. **Merge Dependabot pull requests** when CI is green (monthly).
5. **Release** when enough has landed: Actions → Release.

## Issues

Issues arrive through the forms in `.github/ISSUE_TEMPLATE` (bug report, feature request). Questions are sent to
Discussions and security problems to a private advisory, so neither becomes a public issue.

When an issue is opened by someone else, the **Triage** bot replies: thanks, don't start coding until the issue is
`approved`, and a link to the FAQ for Telegram account problems.

### Deciding

| Situation | Do this |
|---|---|
| Not enough information to act | Label `needs-info` and ask one specific question. The **Stale** bot marks it `stale` after 7 days without a reply and closes it 7 days later. Any reply removes both labels. |
| A real bug | Label `bug` (plus `platform: …` / `area: …`). Add `approved` if a contributor may fix it. |
| A good idea you want | Label `enhancement` and `approved`. Say briefly what an acceptable change looks like. |
| An idea you won't do | Close as **not planned**, link [docs/not-planned.md](docs/not-planned.md) (add the idea there if it's likely to come back). |
| Already reported | Label `duplicate`, link the original, close. |
| Telegram's problem (frozen, banned, login codes) | Link the [FAQ](docs/FAQ.md#when-something-goes-wrong-in-telegram) and close. |
| Easy first task | Add `good first issue` (with `approved`). `help wanted` for anything you'd like help with. |

`approved` is the only green light for code. Never treat a comment or reaction as approval; the bots don't.

### Saved replies

GitHub → Settings → Saved replies, so these are one click in any comment box:

- **Needs info:** "Thanks! To look into this I need: <what>. Settings → Logs → Share gives a log with phone
  numbers and IDs already removed."
- **Approved:** "Approved. Happy to take a pull request: link this issue with `Closes #<n>`. Keep it to this change."
- **Not planned:** "Thanks for the idea. It doesn't fit what Memvo is for right now; the reasons are in
  docs/not-planned.md. Closing, but the discussion stays here."
- **Telegram account:** "This is decided by Telegram, not Memvo, so only Telegram can change it. The FAQ explains
  what to do: docs/FAQ.md#when-something-goes-wrong-in-telegram. Your photos on the phone are untouched."

## Pull requests

What happens on every pull request, in order:

1. **Triage** checks the linked issue (`Closes #n`). Not `approved` → the pull request is closed with an explanation;
   it reopens by itself once the issue is approved and the description is edited. Docs-only changes (`*.md`,
   `docs/`, `website/`) are exempt.
2. **CLA**: a first-time contributor comments the sentence the bot asks for; the signature is stored on the
   `cla-signatures` branch (never protect or delete that branch).
3. **CI** (`ci.yml`): "What changed" (also checks the website pages are regenerated), "Core unit tests" and
   "iOS and Mac" (Mac build, iOS tests including UI tests, iOS Release build, zero warnings in our code).
   Docs-only changes skip the macOS jobs.
4. **CodeRabbit** posts a review limited to real problems (data loss, crashes, main-thread work, leaks of keys or
   personal data). Useful commands in a comment: `@coderabbitai review` (re-review), `@coderabbitai resolve`
   (mark its comments resolved), `@coderabbitai pause` / `resume`.
5. **You review.** Check against [AGENTS.md](AGENTS.md) (house rules): photos are never deleted or marked backed up
   without verification, nothing blocks the main thread, no new dependency without an approved issue, the storage
   identifiers in [docs/CLOUD_FORMAT.md](docs/CLOUD_FORMAT.md) never change. Try anything that touches backup or
   restore on a real iPhone ([docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)).
6. **Labels for the release notes**: `enhancement` → New, `bug` → Fixes, `documentation` → Documentation, anything
   else → Other changes, `skip-changelog` → left out.
7. **Squash and merge.** The title becomes the commit message, so make it a plain sentence. The branch is deleted
   automatically.

### Branch protection

`main` is protected by a ruleset: changes go through a pull request, the three CI checks must pass, force pushes
and deletion are blocked. You can bypass in an emergency (a broken CI runner, a security fix), but the bypass is
logged; prefer a pull request.

### Dependabot

Opens one pull request a month per outdated GitHub Action. CI runs on it; merge when green. If it fails, comment
`@dependabot recreate` once; if it fails again, look at the log before merging anything.

## Security reports

They arrive privately: Security → Advisories. Acknowledge within a few days, fix on a private fork from the
advisory, release, then publish the advisory. Never discuss details in a public issue. Policy: [SECURITY.md](SECURITY.md).

## Releases

Actions → **Release** → app (ios, macos, both), channel (beta, stable), version. It builds, tags, publishes the
GitHub release with grouped notes and, once the App Store Connect secrets exist, uploads to TestFlight. Before a
stable release: move the "Unreleased" section of [docs/CHANGELOG.md](docs/CHANGELOG.md) under the new version and
run `python3 Scripts/website-pages.py`. Full details: [docs/RELEASING.md](docs/RELEASING.md); App Store steps:
[docs/APP_STORE_RELEASE.md](docs/APP_STORE_RELEASE.md).

## Website

`website/` is deployed by Cloudflare on every push to `main` (connected in the Cloudflare dashboard, no GitHub
secret). `privacy.html` and `changelog.html` are generated: edit `PRIVACY.md` or `docs/CHANGELOG.md`, then run
`python3 Scripts/website-pages.py`. Screenshots: `Scripts/website-shots.sh`.

## Services and apps connected to the repository

| What | Does | Where to manage it |
|---|---|---|
| GitHub Actions | CI, Release, Triage, CLA, Stale, label sync | `.github/workflows/` |
| CodeRabbit (GitHub app) | Automated pull request review | `.coderabbit.yaml`, github.com/apps/coderabbitai |
| Dependabot | Monthly GitHub Actions updates, security alerts | `.github/dependabot.yml`, Settings → Code security |
| CLA Assistant (workflow) | Contributor agreement signatures | `.github/workflows/cla.yml`, `cla-signatures` branch |
| Secret scanning + push protection | Blocks commits containing keys | Settings → Code security |
| Cloudflare Workers Builds | Deploys the website | Cloudflare dashboard → Workers & Pages → memvo |

**Repository secrets:** `TD_API_ID`, `TD_API_HASH` (Telegram app keys for builds made on GitHub), and later
`APPLE_TEAM_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` (TestFlight). Set them with `gh secret set NAME -R
shahil-kv/Memvo`, which asks for the value; never paste them anywhere else.

## Tools worth having

- **GitHub app** (iPhone): notifications, quick labels, merging from anywhere.
- **GitHub CLI** (`brew install gh`) with these commands you'll use most:
  ```sh
  gh issue list --label needs-info          # waiting on reporters
  gh issue edit 12 --add-label approved     # green light
  gh pr list                                # open pull requests
  gh pr checks 34                           # CI state of one
  gh pr merge 34 --squash --delete-branch   # merge
  gh run list -L 5                          # recent workflow runs
  ```
- **gh-dash** (`gh extension install dlvhdr/gh-dash`): issues and pull requests in one terminal dashboard.
- **Xcode** and **XcodeGen** (`brew install xcodegen`) for building; see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).
