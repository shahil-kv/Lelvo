#!/usr/bin/env python3
"""Moves the website to a new address: every canonical link, share tag, sitemap entry and the robots file.

    python3 Scripts/website-domain.py memvo.app

Run it once after the new domain serves the site, then commit the changed files. The steps around it (Cloudflare,
Search Console) are in docs/WEBSITE.md.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FILES = ["website/index.html", "website/robots.txt", "website/sitemap.xml", "Scripts/page.template.html"]


def main() -> int:
    if len(sys.argv) != 2 or not re.fullmatch(r"[a-z0-9.-]+\.[a-z]{2,}", sys.argv[1]):
        print("Usage: python3 Scripts/website-domain.py memvo.app", file=sys.stderr)
        return 1
    new = f"https://{sys.argv[1]}"
    old = re.search(r"https://[a-z0-9.-]+", (ROOT / "website/robots.txt").read_text().split("Sitemap:")[1]).group(0)
    if old == new:
        print(f"Already on {new}")
        return 0
    for name in FILES:
        path = ROOT / name
        text = path.read_text()
        path.write_text(text.replace(old, new))
        print(f"{name}: {text.count(old)} links moved")
    print("Now run: python3 Scripts/website-pages.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
