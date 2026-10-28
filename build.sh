#!/bin/sh
# Builds a universal (Apple silicon + Intel) Tacet.app next to this script.
# Requires the Xcode command line tools. Set ARCHS="arm64" for a faster single-architecture build.
set -e
cd "$(dirname "$0")"
APP=Tacet.app
ARCHS="${ARCHS:-arm64 x86_64}"
rm -rf "$APP" build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/Tacet.icns "$APP/Contents/Resources/Tacet.icns"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
cp Resources/public_suffix_list.txt Resources/TacetGuide.md "$APP/Contents/Resources/"
SLICES=""
for ARCH in $ARCHS; do
    find Sources -name '*.swift' -print0 | xargs -0 swiftc -O -swift-version 5 -parse-as-library \
        -target "$ARCH-apple-macosx14.0" -lsqlite3 -o "build/Tacet-$ARCH"
    SLICES="$SLICES build/Tacet-$ARCH"
done
lipo -create $SLICES -output "$APP/Contents/MacOS/Tacet"
rm -rf build
# Signed with the "Tacet Developer" certificate when this Mac has it, so every build is the same app to macOS and the
# Keychain stops asking again after updates. Anyone else gets an ad hoc signature, which works the same otherwise.
IDENTITY=$(security find-identity -p codesigning 2>/dev/null | awk '/"Tacet Developer"/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP"
SIGNED="ad hoc"; [ -n "$IDENTITY" ] && SIGNED="with Tacet Developer"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Tacet"), signed $SIGNED)"
