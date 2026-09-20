#!/bin/bash
set -euo pipefail
rm -rf build/Simulator build/UnitTests.xcresult build/PhotosIntegration.xcresult build/photos-attachments
mkdir -p build
device=$(xcrun simctl list devices available -j | python3 -c 'import json,re,sys; d=json.load(sys.stdin); candidates=[]
for runtime, devices in d["devices"].items():
    if "iOS" not in runtime: continue
    version=tuple(map(int, re.findall(r"\\d+", runtime)))
    for device in devices:
        if "iPhone" in device["name"]: candidates.append((version, device))
if not candidates: raise SystemExit("No available iPhone simulator")
print(max(candidates, key=lambda item: (item[0], item[1]["name"]))[1]["udid"])')
xcrun simctl boot "$device" || true
xcrun simctl bootstatus "$device" -b
collect_extension_log() {
  xcrun simctl spawn "$device" log show --last 30m --style compact \
    --predicate 'process == "PhotoEditingExtension" OR eventMessage CONTAINS "PhotoEditingExtension"' \
    > build/photo-editing-extension.log 2>&1 || true
}
trap collect_extension_log EXIT
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
