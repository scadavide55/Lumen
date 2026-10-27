#!/bin/sh
# Builds a universal (Apple silicon + Intel) Lumen.app next to this script.
# Requires the Xcode command line tools. Set ARCHS="arm64" for a faster single-architecture build.
set -e
cd "$(dirname "$0")"
APP=Lumen.app
ARCHS="${ARCHS:-arm64 x86_64}"
rm -rf "$APP" build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/Lumen.icns "$APP/Contents/Resources/Lumen.icns"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
cp Resources/public_suffix_list.txt "$APP/Contents/Resources/"
SLICES=""
for ARCH in $ARCHS; do
    find Sources -name '*.swift' -print0 | xargs -0 swiftc -O -swift-version 5 -parse-as-library \
        -target "$ARCH-apple-macosx14.0" -lsqlite3 -o "build/Lumen-$ARCH"
    SLICES="$SLICES build/Lumen-$ARCH"
done
lipo -create $SLICES -output "$APP/Contents/MacOS/Lumen"
rm -rf build
codesign --force --sign - "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Lumen"))"
