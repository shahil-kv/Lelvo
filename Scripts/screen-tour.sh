#!/usr/bin/env bash
# Screenshots every first-run screen in light and dark mode on an iOS simulator, into build/tour/<appearance>/.
#   Scripts/screen-tour.sh                 uses the simulator in build/qa-sim.txt, or the newest iPhone
#   SIMULATOR_ID=<udid> Scripts/screen-tour.sh
set -euo pipefail
cd "$(dirname "$0")/.."

udid="${SIMULATOR_ID:-$(cat build/qa-sim.txt 2>/dev/null || true)}"
[ -n "$udid" ] || { echo "Set SIMULATOR_ID or create one into build/qa-sim.txt" >&2; exit 64; }
xcrun simctl boot "$udid" 2>/dev/null || true

[ -d Lelvo.xcodeproj ] && [ Lelvo.xcodeproj -nt project.yml ] || xcodegen generate --quiet
common=(-project Lelvo.xcodeproj -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages)
xcodebuild "${common[@]}" -scheme Lelvo -destination "id=$udid" build-for-testing > build/tour-build.log 2>&1 \
  || { grep -E 'error:' build/tour-build.log | head; exit 1; }

status=0
for look in light dark; do
  out="$PWD/build/tour/$look"; rm -rf "$out"; mkdir -p "$out"
  xcrun simctl ui "$udid" appearance "$look"
  TEST_RUNNER_CG_SCREENSHOT_DIR="$out" xcodebuild "${common[@]}" -scheme Lelvo -destination "id=$udid" \
    -only-testing:LelvoUITests/ScreenTourTests test-without-building > "build/tour-$look.log" 2>&1 \
    && echo "$look: $(ls "$out" | wc -l | tr -d ' ') screens in $out" \
    || { echo "$look: FAILED, see build/tour-$look.log"; grep -E 'error:|failed' "build/tour-$look.log" | head -5; status=1; }
done
exit $status
