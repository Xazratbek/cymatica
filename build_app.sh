#!/bin/bash
# Builds build/Cymatica.app (release, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/Cymatica.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Cymatica "$APP/Contents/MacOS/Cymatica"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

echo "Built $APP"
echo "Run:  open \"$APP\""
echo "Demo: open \"$APP\" --args --demo"
