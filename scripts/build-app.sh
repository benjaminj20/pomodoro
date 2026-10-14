#!/usr/bin/env bash
# Builds build/Pomodoro.app with swiftc directly (no Xcode or SwiftPM needed).
#   scripts/build-app.sh            # release build
#   CONFIG=debug scripts/build-app.sh
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
APP="build/Pomodoro.app"
ARCH="$(uname -m)"

mkdir -p build
if [[ "$CONFIG" == "release" ]]; then
  OPT_FLAGS=(-O)
else
  OPT_FLAGS=(-Onone -g)
fi

echo "› Compiling ($CONFIG, $ARCH)…"
scripts/swiftc.sh "${OPT_FLAGS[@]}" \
  -target "$ARCH-apple-macos14.0" \
  -swift-version 5 \
  -o build/Pomodoro \
  Sources/Pomodoro/*.swift

echo "› Bundling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/Pomodoro "$APP/Contents/MacOS/Pomodoro"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc signature so macOS will launch it and allow notifications/login items.
codesign --force --sign - "$APP" 2>/dev/null
echo "✓ Built ${APP}"
