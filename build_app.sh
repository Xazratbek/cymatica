#!/bin/bash
# Builds build/Cymatica.app (release, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/Cymatica.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Cymatica "$APP/Contents/MacOS/Cymatica"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

echo "Built $APP"
echo "Run:  open \"$APP\""
echo "Demo: open \"$APP\" --args --demo"
