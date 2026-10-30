#!/usr/bin/env python3
"""Writes Memvo's colours and web type from design/tokens.json, so each is defined in one place only:

    app.colors  → iOS/ and macOS/Resources/Assets.xcassets/<Name>.colorset (light and dark)
    web         → the :root block at the top of website/styles.css
    web-dark    → the :root[data-theme="dark"] block after it (the site's theme toggle)

Run from the repository root after editing the tokens:  python3 Scripts/design-tokens.py
With --check it changes nothing and exits 1 if a generated file is out of date.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOKENS = ROOT / "design/tokens.json"
CATALOGS = [ROOT / "iOS/Resources/Assets.xcassets", ROOT / "macOS/Resources/Assets.xcassets"]
STYLES = ROOT / "website/styles.css"
ROOT_BLOCK = re.compile(r'\A:root \{\n.*?\n\}\n(?::root\[data-theme="dark"\] \{\n.*?\n\}\n)?', re.S)


def components(hex_color: str) -> str:
    r, g, b = (int(hex_color[i:i + 2], 16) / 255 for i in (1, 3, 5))
    return (f'"color-space" : "srgb", "components" : {{ "alpha" : "1.000", '
            f'"blue" : "{b:.3f}", "green" : "{g:.3f}", "red" : "{r:.3f}" }}')


def colorset(color: dict) -> str:
    # Same layout as Xcode's own colour sets, so editing one in Xcode gives a small diff.
    return (
        '{\n  "colors" : [\n'
        f'    {{ "color" : {{ {components(color["light"])} }}, "idiom" : "universal" }},\n'
        '    { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ],\n'
        f'      "color" : {{ {components(color["dark"])} }}, "idiom" : "universal" }}\n'
        '  ],\n  "info" : { "author" : "xcode", "version" : 1 }\n}\n'
    )


def root_block(web: dict, dark: dict) -> str:
    def lines(tokens: dict) -> str:
        return "\n".join(f"  --{name}: {value};" for name, value in tokens.items() if not name.startswith("$"))
    return (":root {\n  /* Generated from design/tokens.json by Scripts/design-tokens.py. Edit the tokens, not this block. */\n"
            f"{lines(web)}\n  color-scheme: light;\n}}\n"
            f':root[data-theme="dark"] {{\n{lines(dark)}\n  color-scheme: dark;\n}}\n')


def main() -> int:
    check = "--check" in sys.argv[1:]
    tokens = json.loads(TOKENS.read_text())
    outputs: dict[Path, str] = {}

    for name, color in tokens["app"]["colors"].items():
        for catalog in CATALOGS:
            outputs[catalog / f"{name}.colorset/Contents.json"] = colorset(color)

    css = STYLES.read_text()
    if not ROOT_BLOCK.search(css):
        print(f"{STYLES.relative_to(ROOT)} must start with a :root {{ … }} block", file=sys.stderr)
        return 1
    outputs[STYLES] = ROOT_BLOCK.sub(lambda _: root_block(tokens["web"], tokens["web-dark"]), css, count=1)

    stale = [path for path, text in outputs.items() if not path.exists() or path.read_text() != text]
    for path in stale:
        print(("out of date: " if check else "wrote ") + str(path.relative_to(ROOT)))
        if not check:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(outputs[path])
    if check and stale:
        print("Run python3 Scripts/design-tokens.py", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
