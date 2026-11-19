#!/bin/zsh
# iPhone fault runs on the "Lelvo QA" simulator (real test library). Each test needs photos waiting, or no send
# happens and the fault never fires (OPEN_ISSUES I19), so 6 new photos are added before each one.
# Usage: Scripts/qa/ios-faults.sh <seed.jpg> [test ...]
U=${QA_SIM:-A91C4598-2636-4871-AB8F-1276D53276FE}; T=LelvoUITests/RealAccountChangesTests; seed=$1; shift
tests=(${@:-testT1_floodWaitHonoured testL4_offlineMidRun testI8_sessionRevoked testI8_channelGone testI8_diskFull})
mkdir -p build/qa
for t in $tests; do
  d=build/qa/fresh-$t; rm -rf $d; mkdir -p $d
  for i in 1 2 3 4 5 6; do sips -z $((600+RANDOM%400)) $((800+RANDOM%400)) $seed --out $d/$t-$i.jpg >/dev/null; done
  xcrun simctl addmedia $U $d/*.jpg
  TEST_RUNNER_QA_DIR=$PWD/build/qa xcodebuild -project Lelvo.xcodeproj -scheme Lelvo -destination "id=$U" test-without-building -only-testing:$T/$t > build/qa/$t.log 2>&1
  echo "$t: $(grep -oE "Test Case .*(passed|failed|skipped)" build/qa/$t.log | grep -oE 'passed|failed|skipped' | tail -1)"
  grep -E 'error:' build/qa/$t.log | cut -d: -f4- | head -3
done
