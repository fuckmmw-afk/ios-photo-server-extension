#!/bin/bash
set -euo pipefail
selected=$(python3 - <<'PY'
import glob, os, re
paths=[]
for path in glob.glob('/Applications/Xcode*.app'):
    if any(x in path.lower() for x in ('beta', 'preview', 'rc')): continue
    nums=re.findall(r'\d+', os.path.basename(path))
    paths.append((tuple(map(int,nums)) if nums else (0,), path))
if not paths: raise SystemExit('No stable Xcode found')
print(sorted(paths)[-1][1])
PY
)
sudo xcode-select -s "$selected/Contents/Developer"
xcodebuild -version
xcodebuild -showsdks
xcrun simctl list runtimes
