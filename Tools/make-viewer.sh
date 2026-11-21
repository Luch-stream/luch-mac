#!/bin/bash
# Builds LuchViewer.app — the Mac as a Luch receiver. It needs Local Network access (Bonjour and the
# control channel), not Screen Recording.
#
#   ./Tools/make-viewer.sh
#   SIGN_ID="<your code-signing identity>" ./Tools/make-viewer.sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."

APP=".build/LuchViewer.app"
BIN=".build/release/LuchViewer"

if pgrep -f "LuchViewer.app/Contents/MacOS/LuchViewer" >/dev/null 2>&1; then
    echo "LuchViewer.app is running — quit it from the menu first"
    exit 1
fi

export CLANG_MODULE_CACHE_PATH="$PWD/.mc" SWIFT_MODULECACHE_PATH="$PWD/.mc"
swift build --disable-sandbox -c release --cache-path ./.spm-cache --scratch-path ./.build

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LuchViewer"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>LuchViewer</string>
    <key>CFBundleIdentifier</key><string>dev.luch.viewer</string>
    <key>CFBundleName</key><string>Luch Viewer</string>
    <key>CFBundleDisplayName</key><string>Luch Viewer</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Luch Viewer finds senders on the local network with Bonjour and receives the picture from them.</string>
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
    echo "signed ad-hoc (the Local Network grant is asked again after every rebuild; pass SIGN_ID to keep it)"
fi
echo "built $APP"
echo "run: open $APP"
