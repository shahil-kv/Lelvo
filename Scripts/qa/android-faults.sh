#!/bin/zsh
# Android fault runs on the signed-in emulator ("Android Test" library only). 6 new photos, fault set, a backup run,
# then a clean run. Usage: Scripts/qa/android-faults.sh <seed.jpg> [spec ...]   specs: "flood 2 25" "offline 2 40" "revoke 2" "channel 2"
P=app.lelvo.android; A=$P/.MainActivity; LOG=no_backup/logs/lelvo.log; seed=$1; shift
specs=(${@:-"flood 2 25" "offline 2 40" "revoke 2" "channel 2"})
alog(){ adb shell run-as $P cat $LOG; }
adb shell mkdir -p /sdcard/DCIM/Camera
mkdir -p build/qa
for spec in $specs; do
  # The fault goes in first: automatic backup picks new photos up as soon as they appear.
  start=$(( $(alog | wc -l) + 1 ))
  adb shell am start -n $A --es lelvo.faults "'$spec'" >/dev/null; sleep 2
  tag=${spec// /_}; d=build/qa/and-$tag; rm -rf $d; mkdir -p $d
  for i in 1 2 3 4 5 6; do sips -z $((600+RANDOM%400)) $((800+RANDOM%400)) $seed --out $d/and-$tag-$i.jpg >/dev/null; adb push -q $d/and-$tag-$i.jpg /sdcard/DCIM/Camera/and-$tag-$i-$RANDOM.jpg >/dev/null; done
  adb shell content call --uri content://media/external/file --method scan_volume --arg external_primary >/dev/null 2>&1
  adb shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file:///sdcard/DCIM/Camera >/dev/null 2>&1
  adb shell am start -n $A --es lelvo.work backup.newPhotos >/dev/null; sleep 150
  echo "== $spec"; alog | tail -n +$start | grep -E 'injected|queued|finished|stopp|will stop|FLOOD|failed|Backed up' | cut -c12-190 | uniq | tail -8
  adb shell am start -n $A --es lelvo.faults off >/dev/null; sleep 2
  start=$(( $(alog | wc -l) + 1 ))
  adb shell am start -n $A --es lelvo.work backup.newPhotos >/dev/null; sleep 90
  echo "-- clean run"; alog | tail -n +$start | grep -E 'queued|finished|stopp|Backed up' | cut -c12-190 | tail -3
done
