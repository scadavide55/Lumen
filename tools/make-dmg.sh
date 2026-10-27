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
# Upload this next to the .dmg: Lumen only installs updates signed with your key (swift tools/sign-update.swift keygen, once).
swift tools/sign-update.swift sign "Lumen-$VERSION.dmg" >/dev/null
# Lumen 1.5.2 and earlier check downloads against this checksum instead.
shasum -a 256 "Lumen-$VERSION.dmg" | awk '{print $1}' > "Lumen-$VERSION.dmg.sha256"
echo "Lumen-$VERSION.dmg"
echo "Lumen-$VERSION.dmg.sig"
echo "Lumen-$VERSION.dmg.sha256"
