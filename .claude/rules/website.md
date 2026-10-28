---
paths:
  - "website/**"
  - "docs/CHANGELOG.md"
  - "PRIVACY.md"
  - "Scripts/website-pages.py"
---

# Website and changelog

- `website/changelog.html` and `website/privacy.html` are generated from `docs/CHANGELOG.md` and `PRIVACY.md` by
  `python3 Scripts/website-pages.py`. Edit the Markdown, never the generated HTML. Commit both together, or CI's
  "What changed" check fails and skips the build jobs.
- The site is plain HTML, CSS and JS, deployed by Cloudflare on every push to `main`. No build step, no frameworks.
- Changelog entries are user-facing: what changed for the user, one bullet, bold lead words, no internal names.
- Screenshots and images use test photos only, never a real library, phone number or channel link.
