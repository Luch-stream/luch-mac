#!/bin/sh
# Builds libopus for iOS and packages it as an xcframework the project links. Run once after a
# checkout: the binary is generated, not committed.
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK="$ROOT/.tmp-opus"
VERSION=${OPUS_VERSION:-v1.5.2}

mkdir -p "$WORK"
[ -d "$WORK/src" ] || git clone --depth 1 --branch "$VERSION" https://github.com/xiph/opus.git "$WORK/src"

for pair in "device:iphoneos" "sim:iphonesimulator"; do
    name=${pair%%:*}
    sdk=${pair##*:}
    cmake -S "$WORK/src" -B "$WORK/build-$name" -G Xcode \
        -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=18.0 -DCMAKE_OSX_SYSROOT="$sdk" \
        -DOPUS_BUILD_SHARED_LIBRARY=OFF -DOPUS_BUILD_TESTING=OFF -DOPUS_BUILD_PROGRAMS=OFF >/dev/null
    cmake --build "$WORK/build-$name" --config Release --target opus -- -quiet
done

rm -rf "$WORK/out"
mkdir -p "$WORK/out/device" "$WORK/out/sim" "$WORK/out/include"
cp -R "$WORK/src/include/"opus*.h "$WORK/out/include/"
cp "$WORK/build-device/Release-iphoneos/libopus.a" "$WORK/out/device/"
cp "$WORK/build-sim/Release-iphonesimulator/libopus.a" "$WORK/out/sim/"

mkdir -p "$ROOT/Frameworks"
rm -rf "$ROOT/Frameworks/opus.xcframework"
xcodebuild -create-xcframework \
    -library "$WORK/out/device/libopus.a" -headers "$WORK/out/include" \
    -library "$WORK/out/sim/libopus.a" -headers "$WORK/out/include" \
    -output "$ROOT/Frameworks/opus.xcframework"
echo "built $ROOT/Frameworks/opus.xcframework"
