---
name: ship-pr
description: Prepare and open a Memvo pull request - changelog, website pages, commits per issue, PR body. Only when the owner asks to ship or open a PR.
disable-model-invocation: true
---

1. Previous PR first: `gh pr list --author @me --state open`. If one is open and not merged, stop and ask. The next
   PR is opened only after the previous one merges.
2. Fresh base: `git fetch origin && git rebase origin/main` (or `git rebase --onto origin/main <old-branch>` when the
   branch was cut from the previous PR's branch). Re-run checks after a rebase.
3. Each issue has the `approved` label: `gh issue view <n> --json labels`. Docs-only changes skip this.
4. Run the `verify` skill. For fixes to backup, streaming or sign-in, the owner has tested on the phone
   (`/device-test`).
5. User-facing change: add a bullet under `## Unreleased` in `docs/CHANGELOG.md`, then
   `python3 Scripts/website-pages.py` and stage `website/` with it.
6. Commits: one per issue, subject `<area>: what changed` in plain words (`ios:`, `mac:`, `backup:`, `docs:`).
   Never stage `marketing/`, `Config/Secrets.xcconfig`, `build/` or `CLAUDE.local.md`.
7. Show the owner the commit list and diff summary. Push and `gh pr create` only after they say so. Body follows
   `.github/PULL_REQUEST_TEMPLATE.md`, with `Closes #<n>` for each issue and screenshots for UI changes.
8. After it merges: add a build-log row and a Backlog post to `marketing/POSTS.md` (local only, never committed).
