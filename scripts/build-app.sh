#!/usr/bin/env bash
# Builds a release binary and assembles an ad-hoc signed menu bar app bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product SecretaryApp
BIN="$(swift build -c release --show-bin-path)/SecretaryApp"
APP="build/AI Secretary Alarm.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SecretaryApp"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/Sounds "$APP/Contents/Resources/Sounds"
codesign --force --sign - "$APP"
echo "Built $APP"
echo "Install: cp -R \"$APP\" /Applications/ (launch at login requires the app to live there)"
