#!/bin/bash
set -euo pipefail
device=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); phones=[p for k,v in d["devices"].items() if "iOS" in k for p in v if "iPhone" in p["name"]]; print(phones[0]["udid"])')
xcrun simctl boot "$device" || true
xcrun simctl bootstatus "$device" -b
xcodebuild -project PhotoServer.xcodeproj -scheme PhotoServer -configuration Debug \
  -destination "platform=iOS Simulator,id=$device" -derivedDataPath build/Simulator \
  -resultBundlePath build/UnitTests.xcresult CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
  test >build/unit-tests.log 2>&1 || { tail -120 build/unit-tests.log; exit 1; }
xcrun simctl io "$device" screenshot build/simulator-seed.png
xcrun simctl addmedia "$device" build/simulator-seed.png
xcodebuild -project PhotoServer.xcodeproj -scheme PhotosIntegration -configuration Debug \
  -destination "platform=iOS Simulator,id=$device" -derivedDataPath build/Simulator \
  -resultBundlePath build/PhotosIntegration.xcresult CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
  test >build/photos-ui.log 2>&1 || { tail -80 build/photos-ui.log; exit 1; }
