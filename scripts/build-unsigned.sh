#!/bin/bash
set -euo pipefail
mkdir -p build
xcodebuild -project PhotoServer.xcodeproj -scheme PhotoServer -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' build >build/device-build.log 2>&1 || {
  tail -120 build/device-build.log; exit 1;
}
app=build/DerivedData/Build/Products/Release-iphoneos/PhotoServer.app
extension="$app/PlugIns/PhotoEditingExtension.appex"
test -d "$extension"
test "$(/usr/libexec/PlistBuddy -c 'Print NSExtension:NSExtensionPointIdentifier' "$extension/Info.plist")" = com.apple.photo-editing
for bundle in "$app" "$extension"; do
  test ! -e "$bundle/embedded.mobileprovision"
  test ! -e "$bundle/_CodeSignature"
  if codesign -d "$bundle" >/dev/null 2>&1; then echo "Unexpected signature: $bundle"; exit 1; fi
done
package=$(mktemp -d)
mkdir "$package/Payload"
ditto "$app" "$package/Payload/PhotoServer.app"
destination="$PWD/build/PhotoServer-unsigned.ipa"
(cd "$package" && /usr/bin/zip -qry "$destination" Payload)
unzip -t "$destination"
unzip -l "$destination" >build/ipa-contents.txt
python3 scripts/verify-ipa.py "$destination"
