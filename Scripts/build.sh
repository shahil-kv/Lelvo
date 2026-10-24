#!/usr/bin/env bash
# Builds or tests the apps from the command line, with everything kept in build/ (ignored by git).
#   Scripts/build.sh ios [Debug|Release]     iOS app for the simulator
#   Scripts/build.sh mac [Debug|Release]     Mac app
#   Scripts/build.sh test                    core unit tests (fast, no simulator)
#   Scripts/build.sh uitest                  iOS UI tests on a simulator (slow)
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen" >&2; exit 1; }
[ -d CloudGallery.xcodeproj ] && [ CloudGallery.xcodeproj -nt project.yml ] || xcodegen generate --quiet

common=(-project CloudGallery.xcodeproj -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages)
config="${2:-Debug}"

simulator() {
  # The newest available iPhone simulator, unless SIMULATOR is set.
  if [ -n "${SIMULATOR:-}" ]; then echo "$SIMULATOR"; return; fi
  xcrun simctl list devices available | sed -nE 's/^ +(iPhone[^(]+) \(.*/\1/p' | sed 's/ *$//' | tail -1
}

case "${1:-}" in
  ios) xcodebuild "${common[@]}" -scheme CloudGallery -configuration "$config" -destination "generic/platform=iOS Simulator" build ;;
  mac) xcodebuild "${common[@]}" -scheme CloudGalleryMac -configuration "$config" build ;;
  test) (cd Packages/CloudGalleryCore && swift test) ;;
  uitest) xcodebuild "${common[@]}" -scheme CloudGallery -destination "platform=iOS Simulator,name=$(simulator)" test ;;
  *) sed -n '2,6p' "$0"; exit 64 ;;
esac
