#!/usr/bin/env bash
# Takes the feature pictures for the onboarding intro on the "Memvo Screenshots" simulator (set up by
# Scripts/website-shots.sh with free-licence sample photos), in dark mode.
#   Scripts/onboarding-shots.sh   → Shared/Resources/Onboarding.xcassets/feature-*.imageset
set -euo pipefail
cd "$(dirname "$0")/.."
udid=$(xcrun simctl list devices -j | python3 -c "import json,sys;print(next((d['udid'] for r in json.load(sys.stdin)['devices'].values() for d in r if d['name']=='Memvo Screenshots' and d['isAvailable']),''))")
[ -n "$udid" ] || { echo "Run Scripts/website-shots.sh once first to create the simulator with sample photos" >&2; exit 1; }
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl privacy "$udid" grant photos com.shahil-kv.memvo
xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularMode active --cellularBars 4 --wifiBars 3
xcrun simctl ui "$udid" appearance dark
out="$(pwd)/build/onboarding-shots"; rm -rf "$out"; mkdir -p "$out"
[ -d Memvo.xcodeproj ] || xcodegen generate --quiet
TEST_RUNNER_CG_SCREENSHOT_DIR="$out" xcodebuild test -project Memvo.xcodeproj -scheme Memvo -destination "id=$udid" \
  -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages \
  -only-testing:MemvoUITests/WebsiteScreenshots/testOnboardingFeatures > build/onboarding-shots.log 2>&1 || { tail -40 build/onboarding-shots.log; exit 1; }
xcrun simctl ui "$udid" appearance light
cat_dir=Shared/Resources/Onboarding.xcassets
mkdir -p "$cat_dir"
[ -f "$cat_dir/Contents.json" ] || echo '{"info":{"author":"xcode","version":1}}' > "$cat_dir/Contents.json"
for f in "$out"/feature-*.png; do
  name=$(basename "$f" .png); set_dir="$cat_dir/$name.imageset"; mkdir -p "$set_dir"
  sips -s format jpeg -s formatOptions 80 -Z 1100 "$f" --out "$set_dir/$name.jpg" >/dev/null
  printf '{"images":[{"filename":"%s.jpg","idiom":"universal"}],"info":{"author":"xcode","version":1}}\n' "$name" > "$set_dir/Contents.json"
done
ls "$cat_dir"
