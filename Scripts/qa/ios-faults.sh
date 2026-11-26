#!/bin/zsh
# iPhone fault runs on the "Lelvo QA" simulator (real test library). Each test needs photos waiting, or no send
# happens and the fault never fires (OPEN_ISSUES I19), so 6 new photos are added before each one.
# Usage: Scripts/qa/ios-faults.sh <seed.jpg> [test ...]
U=${QA_SIM:-A91C4598-2636-4871-AB8F-1276D53276FE}; T=LelvoUITests/RealAccountChangesTests; seed=$1; shift
tests=(${@:-testT1_floodWaitHonoured testL4_offlineMidRun testI8_sessionRevoked testI8_channelGone testI8_diskFull})
mkdir -p build/qa
failed=0
for t in $tests; do
  d=build/qa/fresh-$t; rm -rf $d; mkdir -p $d
  for i in 1 2 3 4 5 6; do sips -z $((600+RANDOM%400)) $((800+RANDOM%400)) $seed --out $d/$t-$i.jpg >/dev/null; done
  xcrun simctl addmedia $U $d/*.jpg
  data=$(xcrun simctl get_app_container $U app.lelvo.ios data 2>/dev/null || true)
  log="$data/Library/Application Support/app.lelvo.ios/Logs/lelvo.log"
  start=1; [[ -f "$log" ]] && start=$(( $(wc -l < "$log") + 1 ))
  TEST_RUNNER_QA_DIR=$PWD/build/qa xcodebuild -project Lelvo.xcodeproj -scheme Lelvo -destination "id=$U" test-without-building -only-testing:$T/$t > build/qa/$t.log 2>&1
  status=$(grep -oE "Test Case .*(passed|failed|skipped)" build/qa/$t.log | grep -oE 'passed|failed|skipped' | tail -1)
  # I19: a test that runs with 0 queued sends must fail instead of passing silently.
  if [[ "$status" == "passed" && -f "$log" ]] && ! tail -n +$start "$log" | grep -q "QA: injected"; then
    status="failed (no fault injected — 0 sends?)"
    failed=1
  elif [[ "$status" != "passed" ]]; then
    failed=1
  fi
  echo "$t: $status"
  grep -E 'error:' build/qa/$t.log | cut -d: -f4- | head -3
done
exit $failed
