#!/bin/sh
# Packages Lumen.app into Lumen-<version>.dmg with an Applications shortcut. Run ./build.sh first.
set -e
cd "$(dirname "$0")/.."
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Lumen.app/Contents/Info.plist)
STAGE=$(mktemp -d)
cp -R Lumen.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "Lumen-$VERSION.dmg"
hdiutil create -volname "Lumen $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "Lumen-$VERSION.dmg" >/dev/null
rm -rf "$STAGE"
echo "Lumen-$VERSION.dmg"
