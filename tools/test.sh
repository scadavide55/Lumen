#!/bin/sh
# Builds Tacet's sources together with tools/tests/main.swift and runs the tests.
set -e
cd "$(dirname "$0")/.."
# Every string shown in the app needs its Italian and French translation.
python3 tools/check-translations.py
OUT=$(mktemp -d)
find Sources -name '*.swift' ! -name 'App.swift' -print0 | xargs -0 swiftc -swift-version 5 \
    -target "$(uname -m)-apple-macosx14.0" -lsqlite3 tools/tests/main.swift -o "$OUT/lumen-tests"
# The Public Suffix List is read from next to the executable, as from the app's resources.
cp Resources/public_suffix_list.txt Resources/TacetGuide.md "$OUT/"
"$OUT/lumen-tests"
STATUS=$?
rm -rf "$OUT"
exit $STATUS
