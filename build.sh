#!/bin/sh
# Builds Lumen.app next to this script. Requires Xcode command line tools.
set -e
cd "$(dirname "$0")"
APP=Lumen.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -swift-version 5 -parse-as-library \
    -target arm64-apple-macosx14.0 \
    Sources/Lumen.swift -o "$APP/Contents/MacOS/Lumen"
codesign --force --sign - "$APP"
echo "Built $APP"
