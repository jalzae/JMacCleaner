#!/bin/bash
# Assemble a double-clickable JMacCleaner.app from the SwiftPM release build.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> swift build -c release"
swift build -c release --arch arm64

BIN="$(swift build -c release --arch arm64 --show-bin-path)/JMacCleaner"
APP="build/JMacCleaner.app"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/JMacCleaner"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> ad-hoc codesign"
codesign --force --sign - "$APP"

echo "==> done: $APP"
