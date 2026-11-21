#!/bin/bash
# Builds Luch.app from the SwiftPM executable and signs it. Stable signing matters: Screen Recording
# permission is tied to the signature, and ad-hoc builds need a fresh grant after every rebuild.
#
#   ./Tools/make-app.sh                     # ad-hoc
#   SIGN_ID="<your code-signing identity>" ./Tools/make-app.sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."

APP=".build/Luch.app"
BIN=".build/release/LuchApp"

if pgrep -f "Luch.app/Contents/MacOS/LuchApp" >/dev/null 2>&1; then
    echo "Luch.app is running — quit it from the menu first"
    exit 1
fi

export CLANG_MODULE_CACHE_PATH="$PWD/.mc" SWIFT_MODULECACHE_PATH="$PWD/.mc"
swift build --disable-sandbox -c release --cache-path ./.spm-cache --scratch-path ./.build

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LuchApp"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>LuchApp</string>
    <key>CFBundleIdentifier</key><string>dev.luch.mac</string>
    <key>CFBundleName</key><string>Luch</string>
    <key>CFBundleDisplayName</key><string>Luch</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Luch finds receivers on the local network with Bonjour and streams the screen to them.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_luch._tcp</string>
        <string>_luchsrc._tcp</string>
    </array>
</dict>
</plist>
PLIST

SIGN_ID="${SIGN_ID:-}"
if [ -n "$SIGN_ID" ]; then
    if ! codesign --force --sign "$SIGN_ID" "$APP"; then
        echo "codesign failed with: $SIGN_ID" >&2
        exit 1
    fi
    echo "signed with: $SIGN_ID"
else
    codesign --force --sign - "$APP"
    echo "signed ad-hoc (Screen Recording is asked again after every rebuild; pass SIGN_ID for a stable identity)"
fi
echo "built $APP"
echo "run: open $APP"
