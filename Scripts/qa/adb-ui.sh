#!/bin/zsh
# Small adb helpers for Android QA on the emulator: dump the screen's text, tap by text, screenshot.
#   adb-ui.sh texts            -> every visible text / content description, one per line
#   adb-ui.sh tap "<text>"     -> taps the first node whose text or description starts with it
#   adb-ui.sh shot <file.png>
dump() { adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1; adb shell cat /sdcard/ui.xml; }
case $1 in
  texts) dump | grep -oE '(text|content-desc)="[^"]+"' | sed -E 's/^[a-z-]+="//; s/"$//' ;;
  tap)
    b=$(dump | tr '>' '\n' | grep -E "(text|content-desc)=\"$2" | head -1 | grep -oE 'bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' | grep -oE '[0-9]+')
    [ -z "$b" ] && { echo "no node: $2"; exit 1; }
    set -- ${(f)b}; adb shell input tap $(( ($1+$3)/2 )) $(( ($2+$4)/2 )) ;;
  shot) adb exec-out screencap -p > $2 ;;
esac
