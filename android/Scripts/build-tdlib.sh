#!/usr/bin/env bash
# Builds TDLib for Android with TDLib's own example/android scripts, at the same commit the iPhone app uses
# (TDLibKit 1.5.2-tdlib-1.8.68-18c8f7a0 in project.yml), so both apps speak the same TDLib.
# Output: telegram/src/main/jniLibs/<abi>/libtdjni.so and telegram/src/main/java/org/drinkless/tdlib/*.java
# (both ignored by git). Needs php, perl, gperf and the Android SDK with NDK 27 and CMake 3.22.1.
set -euo pipefail

TD_COMMIT=18c8f7a0
NDK_VERSION=27.1.12297006
MIN_API=29
ABIS="arm64-v8a x86_64"

ANDROID_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
WORK="$ANDROID_DIR/../build/tdlib-android"
mkdir -p "$WORK"

if [ ! -d "$WORK/td" ]; then git clone https://github.com/tdlib/td.git "$WORK/td"; fi
git -C "$WORK/td" fetch -q origin
git -C "$WORK/td" checkout -q "$TD_COMMIT"
EX="$WORK/td/example/android"

# Android 15+ devices can use 16 KB memory pages; Google Play requires native libraries that load on them.
# NDK 27 needs this flag for it (NDK 28+ does it by default).
# perl, not sed -i: the same line runs on macOS and on Linux (GitHub Actions).
perl -pi -e 's/-DTD_ENABLE_PCH:BOOL=ON/-DTD_ENABLE_PCH:BOOL=ON -DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON/' "$EX/build-tdlib.sh"

cd "$EX"
if [ ! -d third-party/openssl ]; then ./build-openssl.sh "$SDK" "$NDK_VERSION"; fi
./build-tdlib.sh "$SDK" "$NDK_VERSION" third-party/openssl c++_static Java "$MIN_API" "$ABIS"
git -C "$WORK/td" checkout -q -- example/android/build-tdlib.sh

for ABI in $ABIS; do
  mkdir -p "$ANDROID_DIR/telegram/src/main/jniLibs/$ABI"
  cp tdlib/libs/$ABI/libtdjni.so "$ANDROID_DIR/telegram/src/main/jniLibs/$ABI/"
done
mkdir -p "$ANDROID_DIR/telegram/src/main/java/org/drinkless/tdlib"
cp tdlib/java/org/drinkless/tdlib/*.java "$ANDROID_DIR/telegram/src/main/java/org/drinkless/tdlib/"
echo "TDLib $TD_COMMIT built for $ABIS"
