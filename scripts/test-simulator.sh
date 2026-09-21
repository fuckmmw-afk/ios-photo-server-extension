#!/bin/bash
set -euo pipefail
rm -rf build/Simulator build/UnitTests.xcresult build/PhotosIntegration.xcresult build/photos-attachments
mkdir -p build
runtime=$(xcrun simctl list runtimes -j | python3 -c 'import json,re,sys
runtimes = json.load(sys.stdin)["runtimes"]
candidates = []
for runtime in runtimes:
    if runtime.get("isAvailable") and runtime.get("name", "").startswith("iOS"):
        version = tuple(map(int, re.findall(r"\\d+", runtime.get("version", ""))))
        candidates.append((version, runtime["identifier"]))
if not candidates: raise SystemExit("No available iOS Simulator runtime")
print(max(candidates)[1])')
device_type=$(xcrun simctl list devicetypes -j | python3 -c 'import json,sys
types = json.load(sys.stdin)["devicetypes"]
for device_type in types:
    if device_type.get("name") == "iPhone 17 Pro":
        print(device_type["identifier"]); break
else:
    for device_type in types:
        if device_type.get("name", "").startswith("iPhone"):
            print(device_type["identifier"]); break
    else: raise SystemExit("No iPhone Simulator device type")')
device=""
collect_extension_log() {
  test -n "$device" || return 0
  xcrun simctl spawn "$device" log show --last 30m --style compact \
    --predicate 'process == "PhotoEditingExtension" OR eventMessage CONTAINS "PhotoEditingExtension"' \
    > build/photo-editing-extension.log 2>&1 || true
}
cleanup() {
  status=$?
  collect_extension_log
  if test -n "$device"; then
    xcrun simctl shutdown "$device" >/dev/null 2>&1 || true
    xcrun simctl delete "$device" >/dev/null 2>&1 || true
  fi
  exit "$status"
}
trap cleanup EXIT

for attempt in 1 2 3; do
  device=$(xcrun simctl create "PhotoServer CI ${GITHUB_RUN_ID:-local}-${attempt}" "$device_type" "$runtime")
  if xcrun simctl boot "$device" && xcrun simctl bootstatus "$device" -b; then
    break
  fi
  xcrun simctl delete "$device" >/dev/null 2>&1 || true
  device=""
done
test -n "$device" || { echo "Unable to boot a fresh iPhone Simulator after 3 attempts." >&2; exit 1; }
xcodebuild -project PhotoServer.xcodeproj -scheme PhotoServer -configuration Debug \
  -destination "platform=iOS Simulator,id=$device" -parallel-testing-enabled NO -derivedDataPath build/Simulator \
  -resultBundlePath build/UnitTests.xcresult \
  test >build/unit-tests.log 2>&1 || { tail -120 build/unit-tests.log; exit 1; }
xcrun simctl io "$device" screenshot build/simulator-seed.png
xcrun simctl addmedia "$device" build/simulator-seed.png
xcodebuild -project PhotoServer.xcodeproj -scheme PhotosIntegration -configuration Debug \
  -destination "platform=iOS Simulator,id=$device" -parallel-testing-enabled NO -derivedDataPath build/Simulator \
  -resultBundlePath build/PhotosIntegration.xcresult \
  test >build/photos-ui.log 2>&1 || { tail -120 build/photos-ui.log; exit 1; }
xcrun xcresulttool get test-results summary --path build/PhotosIntegration.xcresult > build/photos-summary.json
python3 -c 'import json,sys; r=json.load(open("build/photos-summary.json")); passed=r.get("passedTests", 0); skipped=r.get("skippedTests", 0); sys.exit("Photos integration must pass, not skip (passed=%s, skipped=%s)" % (passed, skipped) if passed < 1 or skipped else 0)'
