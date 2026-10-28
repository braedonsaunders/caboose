#!/bin/sh
# Render the iOS app icon from the generated brand SVG (.github/assets/caboose-app-icon.svg,
# itself produced by apps/web/src/brand/brand.ts). macOS only: Quick Look rasterises the SVG,
# then png-flatten.py drops the alpha channel losslessly, because App Store icons must be opaque.
set -eu
root=$(cd "$(dirname "$0")/../../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
qlmanage -t -s 1024 -o "$work" "$root/.github/assets/caboose-app-icon.svg" >/dev/null
python3 -I "$root/apps/ios/scripts/png-flatten.py" "$work/caboose-app-icon.svg.png" \
  "$root/apps/ios/Caboose/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
sips -z 180 180 "$root/apps/ios/Caboose/Assets.xcassets/AppIcon.appiconset/icon-1024.png" \
  --out "$root/apps/web/public/apple-touch-icon.png" >/dev/null
echo "Rendered icon-1024.png and the console's apple-touch-icon.png"
