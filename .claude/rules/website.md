---
paths:
  - "website/**"
  - "website-worker.js"
  - "docs/CHANGELOG.md"
  - "docs/ABOUT.md"
  - "PRIVACY.md"
  - "Scripts/website-pages.py"
---

# Website and changelog

- `website/changelog.html`, `website/privacy.html` and `website/about.html` are generated from `docs/CHANGELOG.md`,
  `PRIVACY.md` and `docs/ABOUT.md` by `python3 Scripts/website-pages.py`. Edit the Markdown, never the generated HTML. Commit both together, or CI's
  "What changed" check fails and skips the build jobs.
- The site is plain HTML, CSS and JS at `https://lelvo.app`, deployed by Cloudflare on every push to `main`. No build
  step, no frameworks. `website-worker.js` only redirects old addresses; keep its workers.dev redirect for older builds.
- The FAQ answers also live in the structured data in `website/index.html`. Change both together.
- Changelog entries are user-facing: what changed for the user, one bullet, bold lead words, no internal names.
- Screenshots and images use test photos only, never a real library, phone number or channel link.
