#!/usr/bin/env python3
"""Builds the website's text pages from the repository's Markdown, so each exists in one place only:

    PRIVACY.md         → website/privacy.html    (the App Store privacy policy URL)
    docs/CHANGELOG.md  → website/changelog.html

Run from the repository root after editing either file:  python3 Scripts/website-pages.py
Handles the Markdown these files use: headings, paragraphs, bullet lists, bold, inline code and links.
"""
import html
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REPO = "https://github.com/shahil-kv/Memvo/blob/main/"

PAGES = [
    ("PRIVACY.md", "privacy",
     "Memvo's privacy policy: Memvo has no servers and collects nothing. Your photos go from your device to your own Telegram account."),
    ("docs/CHANGELOG.md", "changelog", "What's new in each version of Memvo for iPhone and Mac."),
]


def inline(text: str, base: str) -> str:
    text = html.escape(text, quote=False)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)

    def link(m: re.Match) -> str:
        label, href = m.group(1), m.group(2)
        if not re.match(r"^(https?:|mailto:|#)", href):
            href = REPO + str(Path(base) / href)  # a file in the repository, relative to the Markdown file
        return f'<a href="{html.escape(href)}">{label}</a>'

    return re.sub(r"\[([^\]]+)\]\(([^)]+)\)", link, text)


def convert(md: str, base: str) -> tuple[str, str]:
    title, out, para, items = "", [], [], []

    def flush():
        if para:
            out.append(f"<p>{inline(' '.join(para), base)}</p>")
            para.clear()
        if items:
            out.append("<ul>" + "".join(f"<li>{inline(i, base)}</li>" for i in items) + "</ul>")
            items.clear()

    for line in md.splitlines():
        s = line.strip()
        if s.startswith("# "):
            flush(); title = s[2:]
        elif s.startswith("### "):
            flush(); out.append(f"<h3>{inline(s[4:], base)}</h3>")
        elif s.startswith("## "):
            flush(); out.append(f"<h2>{inline(s[3:], base)}</h2>")
        elif s.startswith("- "):
            if para: flush()
            items.append(s[2:])
        elif not s:
            flush()
        elif items and line.startswith("  "):
            items[-1] += " " + s  # continuation of a bullet
        else:
            if items: flush()
            para.append(s)
    flush()
    return title, "\n        ".join(out)


def main() -> None:
    template = (ROOT / "Scripts" / "page.template.html").read_text()
    for source, path, description in PAGES:
        title, body = convert((ROOT / source).read_text(), str(Path(source).parent))
        page = (template.replace("{{TITLE}}", html.escape(title)).replace("{{DESCRIPTION}}", html.escape(description))
                .replace("{{PATH}}", path).replace("{{SOURCE}}", source).replace("{{BODY}}", body))
        (ROOT / "website" / f"{path}.html").write_text(page)
        print(f"website/{path}.html updated from {source}")


if __name__ == "__main__":
    main()
