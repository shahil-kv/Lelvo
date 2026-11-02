#!/bin/sh
# Renders design/logo/mark.svg into every app and website icon. macOS only: uses Quick Look (WebKit) to draw the
# SVG, because ImageMagick's own SVG reader drops gradients. Needs ImageMagick (`magick`).
set -eu
cd "$(dirname "$0")/.."
SRC=design/logo/mark.svg
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

qlmanage -t -s 1024 -o "$TMP" "$SRC" >/dev/null 2>&1
FULL="$TMP/mark.svg.png"
magick "$FULL" -alpha off "$TMP/full.png"

# iOS: one full-bleed 1024 square without alpha; the system rounds the corners.
cp "$TMP/full.png" iOS/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png

# macOS: Apple's grid puts an 824 rounded square (radius ~185) in a 1024 canvas, with a soft shadow below it.
magick -size 824x824 xc:none -fill white -draw "roundrectangle 0,0 823,823 185,185" "$TMP/mask.png"
magick "$TMP/full.png" -resize 824x824 "$TMP/mask.png" -compose CopyOpacity -composite "$TMP/body.png"
magick "$TMP/body.png" \( +clone -background black -shadow 35x14+0+10 \) +swap -background none -layers merge +repage \
  -gravity center -background none -extent 1024x1024 "$TMP/mac.png"
MAC=macOS/Resources/Assets.xcassets/AppIcon.appiconset
for s in 16 32 128 256 512; do
  magick "$TMP/mac.png" -resize ${s}x${s} "$MAC/icon_${s}x${s}@1x.png"
  magick "$TMP/mac.png" -resize $((s * 2))x$((s * 2)) "$MAC/icon_${s}x${s}@2x.png"
done

# Website: touch icon is full-bleed like iOS; manifest icons get rounded corners.
magick "$TMP/full.png" -resize 180x180 website/apple-touch-icon.png
magick -size 1024x1024 xc:none -fill white -draw "roundrectangle 0,0 1023,1023 228,228" "$TMP/mask1024.png"
magick "$TMP/full.png" "$TMP/mask1024.png" -compose CopyOpacity -composite "$TMP/round.png"
magick "$TMP/round.png" -resize 192x192 website/icon-192.png
magick "$TMP/round.png" -resize 512x512 website/icon-512.png
echo "Icons written."
