#!/bin/sh
# Builds Lumen.app next to this script. Requires Xcode command line tools.
set -e
cd "$(dirname "$0")"
APP=Lumen.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/Lumen.icns "$APP/Contents/Resources/Lumen.icns"
find Sources -name '*.swift' -print0 | xargs -0 swiftc -O -swift-version 5 -parse-as-library \
    -target arm64-apple-macosx14.0 -lsqlite3 -o "$APP/Contents/MacOS/Lumen"
codesign --force --sign - "$APP"
echo "Built $APP"
