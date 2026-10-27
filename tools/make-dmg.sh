#!/bin/sh
# Packages Tacet.app into Tacet-<version>.dmg with an Applications shortcut. Run ./build.sh first.
set -e
cd "$(dirname "$0")/.."
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Tacet.app/Contents/Info.plist)
STAGE=$(mktemp -d)
cp -R Tacet.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "Tacet-$VERSION.dmg"
hdiutil create -volname "Tacet $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "Tacet-$VERSION.dmg" >/dev/null
rm -rf "$STAGE"
# Upload this next to the .dmg: Tacet only installs updates signed with your key (swift tools/sign-update.swift keygen, once).
swift tools/sign-update.swift sign "Tacet-$VERSION.dmg" >/dev/null
# Lumen 1.5.2 and earlier check downloads against this checksum instead.
shasum -a 256 "Tacet-$VERSION.dmg" | awk '{print $1}' > "Tacet-$VERSION.dmg.sha256"
echo "Tacet-$VERSION.dmg"
echo "Tacet-$VERSION.dmg.sig"
echo "Tacet-$VERSION.dmg.sha256"
