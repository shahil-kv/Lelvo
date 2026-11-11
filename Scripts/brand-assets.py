#!/usr/bin/env python3
"""Draws everything that shows the Lelvo mark from design/logo/mark.svg and the brand colours in design/tokens.json:

    Shared/Views/Brand/LelvoMark.swift          the mark as SwiftUI shapes, and the brand colours
    iOS AppIcon (default, dark, tinted)         iOS/Resources/Assets.xcassets/AppIcon.appiconset
    macOS AppIcon (16 to 1024)                  macOS/Resources/Assets.xcassets/AppIcon.appiconset
    iOS launch screen                           LaunchMark.imageset and LaunchBackground.colorset
    website icons                               website/favicon.svg, apple-touch-icon.png, icon-192.png, icon-512.png
    Android icon, launch screen, mark           android/app/src/main/res (ic_launcher*, splash_icon, launch_*), LelvoMark.kt
    logo kit to share (press, socials, store)   design/logo/lelvo-*.svg and .png

Run from the repository root after changing the mark or the brand colours:  python3 Scripts/brand-assets.py
Needs resvg (brew install resvg) and ImageMagick for the PNGs.
"""
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MARK = ROOT / "design/logo/mark.svg"
TOKENS = ROOT / "design/tokens.json"
W, H = 1128, 716  # the mark's viewBox


def paths() -> dict[str, str]:
    svg = MARK.read_text()
    return {m.group(1): m.group(2) for m in re.finditer(r'<path id="(\w+)" d="([^"]+)"', svg)}


def mark_group(fill: str, width: float, cx: float, cy: float) -> str:
    """The mark scaled to `width`, centred on (cx, cy)."""
    s = width / W
    p = paths()
    return (f'<g transform="translate({cx - width / 2:.2f} {cy - H * s / 2:.2f}) scale({s:.5f})" fill="{fill}">'
            f'<path d="{p["camel"]}"/><path d="{p["cloud"]}"/></g>')


def gradient(gid: str, brand: dict, size: float) -> str:
    # Bright violet at the bottom left to deep plum at the top right, as in the logo files.
    return (f'<linearGradient id="{gid}" gradientUnits="userSpaceOnUse" x1="0" y1="{size}" x2="{size}" y2="0">'
            f'<stop offset="0" stop-color="{brand["violet"]}"/><stop offset="1" stop-color="{brand["deep"]}"/></linearGradient>')


def svg(size: int, body: str, defs: str = "") -> str:
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {size} {size}"><defs>{defs}</defs>{body}</svg>'


def ios_icon(brand: dict, variant: str) -> str:
    n = 1024
    if variant == "dark":  # on black, the camel in the app's violet and the cloud in white
        s = 640 / W
        p = paths()
        return svg(n, f'<rect width="{n}" height="{n}" fill="#000"/>'
                      f'<g transform="translate({512 - 320:.2f} {520 - H * s / 2:.2f}) scale({s:.5f})">'
                      f'<path d="{p["camel"]}" fill="{brand["violet-light"]}"/><path d="{p["cloud"]}" fill="#FFFFFF"/></g>')
    if variant == "tinted":  # grayscale; iOS applies the person's tint
        return svg(n, f'<rect width="{n}" height="{n}" fill="#000"/>' + mark_group("#FFFFFF", 640, 512, 520))
    return svg(n, f'<rect width="{n}" height="{n}" fill="url(#g)"/>' + mark_group("#FFFFFF", 640, 512, 520),
               gradient("g", brand, n))


def rounded_tile(brand: dict, n: int, inset: float, radius: float, shadow: bool) -> str:
    side = n - 2 * inset
    defs = gradient("g", brand, n)
    filt = ""
    if shadow:  # macOS icons sit on a soft shadow inside the 1024 canvas
        defs += '<filter id="s" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="10" stdDeviation="14" flood-color="#000" flood-opacity="0.28"/></filter>'
        filt = ' filter="url(#s)"'
    tile = f'<rect x="{inset}" y="{inset}" width="{side}" height="{side}" rx="{radius}" fill="url(#g)"{filt}/>'
    return svg(n, tile + mark_group("#FFFFFF", side * 0.64, n / 2, n / 2 + side * 0.008), defs)


def tile(n: int, background: str, mark: str, defs: str = "") -> str:
    """A rounded icon tile with the mark, like the app icon on a Home Screen (iOS corner radius is about 22.4%)."""
    return svg(n, f'<rect width="{n}" height="{n}" rx="{n * 0.2237:.1f}" fill="{background}"/>' + mark, defs)


def two_tone(camel: str, cloud: str, width: float, cx: float, cy: float) -> str:
    s = width / W
    p = paths()
    return (f'<g transform="translate({cx - width / 2:.2f} {cy - H * s / 2:.2f}) scale({s:.5f})">'
            f'<path d="{p["camel"]}" fill="{camel}"/><path d="{p["cloud"]}" fill="{cloud}"/></g>')


def logo_kit(brand: dict) -> None:
    """The logo files to hand out: each as SVG and a 1024 PNG. Light backgrounds take the violet mark, dark ones the
    white or two-tone mark."""
    out = ROOT / "design/logo"
    n = 1024
    mark_gradient = (f'<linearGradient id="v" gradientUnits="userSpaceOnUse" x1="0" y1="{H}" x2="{W}" y2="0">'
                     f'<stop offset="0" stop-color="{brand["violet"]}"/><stop offset="1" stop-color="{brand["deep"]}"/></linearGradient>')
    marks = {
        "lelvo-mark-violet": f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}"><defs>{mark_gradient}</defs>{mark_group("url(#v)", W, W / 2, H / 2)}</svg>',
        "lelvo-mark-white": f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}">{mark_group("#FFFFFF", W, W / 2, H / 2)}</svg>',
        "lelvo-mark-dark": f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}">{two_tone(brand["violet-light"], "#FFFFFF", W, W / 2, H / 2)}</svg>',
    }
    tiles = {
        "lelvo-icon": tile(n, "url(#g)", mark_group("#FFFFFF", 640, 512, 520), gradient("g", brand, n)),
        "lelvo-icon-dark": tile(n, "#000", two_tone(brand["violet-light"], "#FFFFFF", 640, 512, 520)),
        "lelvo-icon-black": tile(n, "#000", mark_group("#FFFFFF", 640, 512, 520)),
    }
    for name, text in marks.items():
        (out / f"{name}.svg").write_text(text + "\n")
        render(text, out / f"{name}.png", 1024, round(1024 * H / W))
    for name, text in tiles.items():
        (out / f"{name}.svg").write_text(text + "\n")
        render(text, out / f"{name}.png", 1024)


def render(svg_text: str, out: Path, width: int, height: int | None = None, opaque: bool = False) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", suffix=".svg", delete=False) as f:
        f.write(svg_text)
    subprocess.run(["resvg", "--width", str(width), "--height", str(height or width), f.name, str(out)], check=True)
    if opaque:  # App Store icons can't have an alpha channel
        subprocess.run(["magick", str(out), "-background", "black", "-alpha", "remove", "-alpha", "off", str(out)], check=True)
    Path(f.name).unlink()


def swift_path(d: str) -> str:
    lines = []
    for cmd, args in re.findall(r"([MCLZ])([^MCLZ]*)", d):
        v = [float(x) for x in args.split()]
        pt = lambda x, y: f"p({x / W:.5f}, {y / H:.5f})"
        if cmd == "M":
            lines.append(f"        path.move(to: {pt(*v)})")
        elif cmd == "L":
            lines.append(f"        path.addLine(to: {pt(*v)})")
        elif cmd == "C":
            lines.append(f"        path.addCurve(to: {pt(v[4], v[5])}, control1: {pt(v[0], v[1])}, control2: {pt(v[2], v[3])})")
        else:
            lines.append("        path.closeSubpath()")
    return "\n".join(lines)


def color(hex_color: str) -> str:
    r, g, b = (int(hex_color[i:i + 2], 16) / 255 for i in (1, 3, 5))
    return f"Color(red: {r:.3f}, green: {g:.3f}, blue: {b:.3f})"


def swift_file(brand: dict) -> str:
    p = paths()
    return f'''// Generated from design/logo/mark.svg and design/tokens.json by Scripts/brand-assets.py. Don't edit by hand.
import SwiftUI

/// The Lelvo mark: a camel whose neck flows into a cloud. Draw it at `LelvoMark.aspectRatio`.
/// The unit paths are built once; `path(in:)` only scales them, so it's cheap to animate.
struct LelvoMark: Shape {{
    enum Part {{ case camel, cloud }}

    /// nil draws both parts.
    var part: Part?

    static let aspectRatio: CGFloat = {W}.0 / {H}.0
    /// Centre of the cloud's bowl, in unit coordinates: where photos fly to.
    static let cloudCenter = UnitPoint(x: 0.745, y: 0.42)
    /// The thickest point of the camel's neck: zooming in on it covers the screen with the mark.
    static let zoomAnchor = UnitPoint(x: 0.343, y: 0.286)

    func path(in rect: CGRect) -> Path {{
        let unit: Path
        switch part {{
        case .camel: unit = Self.camel
        case .cloud: unit = Self.cloud
        case nil: unit = Self.both
        }}
        return unit.applying(CGAffineTransform(a: rect.width, b: 0, c: 0, d: rect.height, tx: rect.minX, ty: rect.minY))
    }}

    private static func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {{ CGPoint(x: x, y: y) }}

    private static let both: Path = {{
        var path = camel
        path.addPath(cloud)
        return path
    }}()

    private static let camel: Path = {{
        var path = Path()
{swift_path(p["camel"])}
        return path
    }}()

    private static let cloud: Path = {{
        var path = Path()
{swift_path(p["cloud"])}
        return path
    }}()
}}

/// Brand colours from the logo, for the launch screen, the mark and big moments. Everyday UI uses the accent.
enum Brand {{
    static let violet = {color(brand["violet"])}
    static let deep = {color(brand["deep"])}
    static let launch = {color(brand["launch"])}
    static let gradient = LinearGradient(colors: [violet, deep], startPoint: .bottomLeading, endPoint: .topTrailing)
}}
'''


ANDROID_RES = ROOT / "android/app/src/main/res"
ANDROID_HEADER = "<!-- Generated from design/logo/mark.svg and design/tokens.json by Scripts/brand-assets.py. Don't edit by hand. -->"


def vector(width_dp: float, height_dp: float, vw: float, vh: float, body: str, aapt: bool = False) -> str:
    ns = ' xmlns:aapt="http://schemas.android.com/aapt"' if aapt else ""
    return (f'<?xml version="1.0" encoding="utf-8"?>\n{ANDROID_HEADER}\n'
            f'<vector xmlns:android="http://schemas.android.com/apk/res/android"{ns}\n'
            f'    android:width="{width_dp:g}dp" android:height="{height_dp:g}dp"\n'
            f'    android:viewportWidth="{vw:g}" android:viewportHeight="{vh:g}">\n{body}</vector>\n')


def vector_mark(fill: str, width: float, cx: float, cy: float) -> str:
    """The mark as a vector group, scaled to `width` and centred on (cx, cy) in viewport units."""
    s = width / W
    p = paths()
    return (f'    <group android:translateX="{cx - width / 2:.3f}" android:translateY="{cy - H * s / 2:.3f}"'
            f' android:scaleX="{s:.6f}" android:scaleY="{s:.6f}">\n'
            f'        <path android:fillColor="{fill}" android:pathData="{p["camel"]}"/>\n'
            f'        <path android:fillColor="{fill}" android:pathData="{p["cloud"]}"/>\n'
            f'    </group>\n')


def kotlin_file(brand: dict) -> str:
    p = paths()
    return f'''// Generated from design/logo/mark.svg and design/tokens.json by Scripts/brand-assets.py. Don't edit by hand.
package app.lelvo.android.ui.theme

/** The Lelvo mark: a camel whose neck flows into a cloud, in the units of its {W} × {H} drawing (iOS `LelvoMark`). */
object LelvoMark {{
    const val WIDTH = {W}f
    const val HEIGHT = {H}f
    const val ASPECT_RATIO = WIDTH / HEIGHT
    /** The width of the mark on the launch screen, in dp: the same as the iPhone's. */
    const val LAUNCH_WIDTH_DP = 124f
    /** The thickest point of the camel's neck, as a fraction of the mark: zooming in on it covers the screen. */
    const val ZOOM_ANCHOR_X = 0.343f
    const val ZOOM_ANCHOR_Y = 0.286f

    const val CAMEL = "{p["camel"]}"
    const val CLOUD = "{p["cloud"]}"
}}
'''


def android(brand: dict) -> None:
    """Adaptive launcher icon (with a themed-icon layer), the launch screen pictures, and the mark for Kotlin."""
    res = ANDROID_RES
    (res / "drawable").mkdir(parents=True, exist_ok=True)
    (res / "mipmap-anydpi-v26").mkdir(parents=True, exist_ok=True)
    (res / "values").mkdir(parents=True, exist_ok=True)
    # Adaptive icons draw on 108 dp and show the middle 72 dp. The mark takes the same share of the visible tile as on
    # the iPhone icon (640 of 1024), a little below the middle like it.
    visible, inset = 72, 18
    width, cy = 640 / 1024 * visible, inset + 520 / 1024 * visible
    (res / "drawable/ic_launcher_background.xml").write_text(vector(108, 108, 108, 108,
        '    <path android:pathData="M0,0h108v108h-108z">\n'
        '        <aapt:attr name="android:fillColor">\n'
        f'            <gradient android:type="linear" android:startX="{inset}" android:startY="{inset + visible}"'
        f' android:endX="{inset + visible}" android:endY="{inset}"\n'
        f'                android:startColor="{brand["violet"]}" android:endColor="{brand["deep"]}"/>\n'
        '        </aapt:attr>\n    </path>\n', aapt=True))
    (res / "drawable/ic_launcher_foreground.xml").write_text(vector(108, 108, 108, 108, vector_mark("#FFFFFF", width, 54, cy)))
    # Themed icons (Android 13+) tint this layer with the wallpaper's colours; only its shape counts.
    (res / "drawable/ic_launcher_monochrome.xml").write_text(vector(108, 108, 108, 108, vector_mark("#FFFFFF", width, 54, cy)))
    adaptive = (f'<?xml version="1.0" encoding="utf-8"?>\n{ANDROID_HEADER}\n'
                '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
                '    <background android:drawable="@drawable/ic_launcher_background"/>\n'
                '    <foreground android:drawable="@drawable/ic_launcher_foreground"/>\n'
                '    <monochrome android:drawable="@drawable/ic_launcher_monochrome"/>\n'
                '</adaptive-icon>\n')
    for name in ("ic_launcher", "ic_launcher_round"):
        (res / f"mipmap-anydpi-v26/{name}.xml").write_text(adaptive)
    # Android 12+ splash icon: an icon without a background is drawn on a 288 dp square (192 dp visible circle).
    # The mark keeps the iPhone's launch width, so the first frame of the opening lines up with it.
    (res / "drawable/splash_icon.xml").write_text(vector(288, 288, 288, 288, vector_mark("#FFFFFF", 124, 144, 144)))
    # Android 10 and 11 have no splash API: the window background shows the same picture.
    (res / "drawable/launch_mark.xml").write_text(vector(124, round(124 * H / W, 2), W, H, vector_mark("#FFFFFF", W, W / 2, H / 2)))
    (res / "drawable/launch_background.xml").write_text(
        f'<?xml version="1.0" encoding="utf-8"?>\n{ANDROID_HEADER}\n'
        '<layer-list xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <item android:drawable="@color/launch"/>\n'
        f'    <item android:drawable="@drawable/launch_mark" android:gravity="center"'
        f' android:width="124dp" android:height="{round(124 * H / W, 2)}dp"/>\n'
        '</layer-list>\n')
    (res / "values/brand.xml").write_text(
        f'<?xml version="1.0" encoding="utf-8"?>\n{ANDROID_HEADER}\n<resources>\n'
        f'    <color name="launch">{brand["launch"]}</color>\n</resources>\n')
    kt = ROOT / "android/app/src/main/kotlin/app/lelvo/android/ui/theme/LelvoMark.kt"
    kt.write_text(kotlin_file(brand))


def colorset(hex_color: str) -> str:
    r, g, b = (int(hex_color[i:i + 2], 16) / 255 for i in (1, 3, 5))
    c = f'"color-space" : "srgb", "components" : {{ "alpha" : "1.000", "blue" : "{b:.3f}", "green" : "{g:.3f}", "red" : "{r:.3f}" }}'
    return '{\n  "colors" : [\n' f'    {{ "color" : {{ {c} }}, "idiom" : "universal" }}\n' \
           '  ],\n  "info" : { "author" : "xcode", "version" : 1 }\n}\n'


def main() -> int:
    for tool in ("resvg", "magick"):
        if not shutil.which(tool):
            print(f"{tool} is missing: brew install {'resvg' if tool == 'resvg' else 'imagemagick'}", file=sys.stderr)
            return 1
    brand = json.loads(TOKENS.read_text())["brand"]

    swift = ROOT / "Shared/Views/Brand/LelvoMark.swift"
    swift.parent.mkdir(parents=True, exist_ok=True)
    swift.write_text(swift_file(brand))

    ios = ROOT / "iOS/Resources/Assets.xcassets"
    icon = ios / "AppIcon.appiconset"
    for variant, name in (("default", "AppIcon.png"), ("dark", "AppIcon-dark.png"), ("tinted", "AppIcon-tinted.png")):
        render(ios_icon(brand, variant), icon / name, 1024, opaque=True)
    (icon / "Contents.json").write_text(json.dumps({
        "images": [
            {"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
            {"appearances": [{"appearance": "luminosity", "value": "dark"}],
             "filename": "AppIcon-dark.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
            {"appearances": [{"appearance": "luminosity", "value": "tinted"}],
             "filename": "AppIcon-tinted.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        ],
        "info": {"author": "xcode", "version": 1},
    }, indent=2) + "\n")

    mac = ROOT / "macOS/Resources/Assets.xcassets/AppIcon.appiconset"
    mac_svg = rounded_tile(brand, 1024, 100, 185, shadow=True)
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            render(mac_svg, mac / f"icon_{size}x{size}@{scale}x.png", size * scale)

    launch = ios / "LaunchMark.imageset"
    for scale in (1, 2, 3):
        mark = f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}">{mark_group("#FFFFFF", W, W / 2, H / 2)}</svg>'
        render(mark, launch / f"LaunchMark@{scale}x.png", 124 * scale, round(124 * scale * H / W))
    (launch / "Contents.json").write_text(json.dumps({
        "images": [{"filename": f"LaunchMark@{s}x.png", "idiom": "universal", "scale": f"{s}x"} for s in (1, 2, 3)],
        "info": {"author": "xcode", "version": 1},
    }, indent=2) + "\n")
    (ios / "LaunchBackground.colorset/Contents.json").write_text(colorset(brand["launch"]))

    web = ROOT / "website"
    favicon = rounded_tile(brand, 1024, 0, 228, shadow=False)
    (web / "favicon.svg").write_text(favicon.replace("<defs>", "<!-- Lelvo mark on the brand tile. Generated by Scripts/brand-assets.py from design/logo/mark.svg. --><defs>", 1) + "\n")
    render(rounded_tile(brand, 1024, 0, 0, shadow=False), web / "apple-touch-icon.png", 180, opaque=True)
    render(favicon, web / "icon-192.png", 192)
    render(favicon, web / "icon-512.png", 512)
    logo_kit(brand)
    android(brand)
    print("wrote", swift.relative_to(ROOT), "the icons and the logo kit")
    return 0


if __name__ == "__main__":
    sys.exit(main())
