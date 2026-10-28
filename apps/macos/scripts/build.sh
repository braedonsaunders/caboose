#!/usr/bin/env bash
# Build an accessory app; the separately signed AppKit helper owns virtualization.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd -P)
out=${1:?usage: build.sh output-directory}
mkdir -p "$out"
out=$(cd "$out" && pwd -P)
swift build --build-system native --disable-sandbox --package-path "$here" -c release -j 2 --product CabooseMenu >&2
bin=$(swift build --build-system native --disable-sandbox --package-path "$here" -c release --show-bin-path)
app=$out/Caboose.app
mkdir -p "$app/Contents/MacOS"
cp "$bin/CabooseMenu" "$app/Contents/MacOS/CabooseMenu"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CabooseMenu</string>
<key>CFBundleIdentifier</key><string>com.caboose.menu</string>
<key>CFBundleName</key><string>Caboose</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign "${CABOOSE_CODESIGN_IDENTITY:--}" "$app"
codesign --verify --strict "$app"
echo "$app"
