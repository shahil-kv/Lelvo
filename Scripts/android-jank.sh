#!/bin/bash
# Android frame and memory check (test plan Phase P on Android): flings the timeline, then reads the system's own
# frame stats (janky frames, 50/90/99th percentile frame time at the device's refresh rate) and the app's memory.
#   Scripts/android-jank.sh [serial] [flings]       app must already be showing the timeline
s=${1:-emulator-5554}; n=${2:-30}; pkg=app.lelvo.android
a() { adb -s "$s" "$@"; }
read w h < <(a shell wm size | sed -E 's/.*: ([0-9]+)x([0-9]+).*/\1 \2/' | tail -1)
x=$((w/2)); lo=$((h*8/10)); hi=$((h*2/10))
a shell dumpsys gfxinfo $pkg reset > /dev/null
for i in $(seq $n); do a shell input swipe $x $lo $x $hi 60; sleep 0.4; done
for i in $(seq $n); do a shell input swipe $x $hi $x $lo 60; sleep 0.4; done
sleep 1
echo "== $(a shell getprop ro.product.model) · RAM $(a shell cat /proc/meminfo | awk '/MemTotal/{printf "%.1f GB", $2/1048576}') · $(a shell dumpsys display | grep -oE 'renderFrameRate [0-9.]+' | head -1)"
a shell dumpsys gfxinfo $pkg | grep -E 'Total frames rendered|Janky frames|50th percentile|90th percentile|95th percentile|99th percentile|Number Slow UI thread|Number Frame deadline missed' | grep -v legacy | sed 's/^ */  /'
a shell dumpsys meminfo $pkg | grep -E 'TOTAL PSS|Java Heap|Native Heap|Graphics' | head -4 | sed 's/^ */  /'
a shell dumpsys activity processes $pkg | grep -cq 'lelvo' || echo "  ✗ app process is gone (killed?)"
