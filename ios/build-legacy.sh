#!/bin/bash
# Build Hexmosphere for iOS 12 (e.g. iPad mini 3) without Xcode's deployment-target check:
# Xcode 27 refuses targets below iOS 15, but clang still compiles for arm64-apple-ios12.0.
# Output: manual/Hexmosphere.app (unsigned). Sign and install separately.
set -euo pipefail
cd "$(dirname "$0")"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
H3=../Packages/CH3/Sources/CH3
OUT=manual
CC=(xcrun -sdk iphoneos clang -target arm64-apple-ios12.0 -isysroot "$SDK" -O2 -fobjc-arc -I"$H3/include" -I"$H3" -w)

rm -rf "$OUT"
mkdir -p "$OUT/obj" "$OUT/Hexmosphere.app"
for f in "$H3"/*.c Sources/*.m; do
  name=$(basename "$f"); "${CC[@]}" -c "$f" -o "$OUT/obj/${name%.*}.o"
done
"${CC[@]}" "$OUT"/obj/*.o -framework UIKit -framework MapKit -framework Photos \
  -framework CoreLocation -framework Foundation -o "$OUT/Hexmosphere.app/Hexmosphere"

cat > "$OUT/Hexmosphere.app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>net.tennica.hexmosphere.legacy</string>
  <key>CFBundleName</key><string>Hexmosphere</string>
  <key>CFBundleDisplayName</key><string>Hexmosphere</string>
  <key>CFBundleExecutable</key><string>Hexmosphere</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
  <key>MinimumOSVersion</key><string>12.0</string>
  <key>UIDeviceFamily</key><array><integer>2</integer></array>
  <key>UIRequiredDeviceCapabilities</key><array><string>arm64</string></array>
  <key>UISupportedInterfaceOrientations~ipad</key>
  <array>
    <string>UIInterfaceOrientationPortrait</string>
    <string>UIInterfaceOrientationPortraitUpsideDown</string>
    <string>UIInterfaceOrientationLandscapeLeft</string>
    <string>UIInterfaceOrientationLandscapeRight</string>
  </array>
  <key>NSPhotoLibraryUsageDescription</key>
  <string>Hexmosphere reads where your photos were taken to draw them as hexagons. Nothing leaves this iPad.</string>
</dict>
</plist>
PLIST
plutil -convert binary1 "$OUT/Hexmosphere.app/Info.plist"
printf 'APPL????' > "$OUT/Hexmosphere.app/PkgInfo"
echo "built $OUT/Hexmosphere.app"
