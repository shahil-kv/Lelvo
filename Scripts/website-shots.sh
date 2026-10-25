#!/usr/bin/env bash
# Takes the app screenshots for the website on a dedicated simulator with sample photos.
#   Scripts/website-shots.sh <folder with sample .jpg/.mp4>    → website/img/<screen>.jpg
# Uses free-licence sample photos only (never your own library).
set -euo pipefail
cd "$(dirname "$0")/.."
media="${1:?Pass a folder of sample photos and videos}"
name="Memvo Screenshots"
type="${DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}"
udid=$(xcrun simctl list devices -j | python3 -c "import json,sys;print(next((d['udid'] for r in json.load(sys.stdin)['devices'].values() for d in r if d['name']=='$name' and d['isAvailable']),''))")
[ -n "$udid" ] || udid=$(xcrun simctl create "$name" "$type")
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b >/dev/null
[ -f build/.website-shots-media ] || { xcrun simctl addmedia "$udid" "$media"/*.jpg "$media"/*.mp4; touch build/.website-shots-media; }
xcrun simctl privacy "$udid" grant photos com.shahil-kv.memvo
xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularMode active --cellularBars 4 --wifiBars 3
out="$(pwd)/build/website-shots"; rm -rf "$out"; mkdir -p "$out"
[ -d Memvo.xcodeproj ] || xcodegen generate --quiet
run() { # $1 = appearance, rest = tests
  local look="$1"; shift
  xcrun simctl ui "$udid" appearance "$look"
  local only=(); for t in "$@"; do only+=("-only-testing:MemvoUITests/WebsiteScreenshots/$t"); done
  TEST_RUNNER_CG_SCREENSHOT_DIR="$out" xcodebuild test -project Memvo.xcodeproj -scheme Memvo -destination "id=$udid" \
    -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages \
    "${only[@]}" > "build/website-shots-$look.log" 2>&1 || { tail -40 "build/website-shots-$look.log"; exit 1; }
}
run light testLibraryScreens testWelcome
run dark testDenseTimelineAndDarkMode
xcrun simctl ui "$udid" appearance light
mkdir -p website/img
for f in "$out"/*.png; do sips -s format jpeg -s formatOptions 82 -Z 1320 "$f" --out "website/img/$(basename "$f" .png).jpg" >/dev/null; done
ls website/img
