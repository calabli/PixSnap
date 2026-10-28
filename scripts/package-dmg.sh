#!/bin/bash
# Builds a release PixSnap.app (Apple silicon + Intel) and packs it into build/PixSnap-<version>.dmg,
# with a shortcut to Applications to drag it onto.
# Usage: scripts/package-dmg.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
scripts/build-app.sh release

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
DMG="$ROOT/build/PixSnap-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R build/PixSnap.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "PixSnap $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

IDENTITY="${PIXSNAP_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application|Apple Development/ {print $2; exit}')}"
[[ -n "$IDENTITY" ]] && codesign --force --sign "$IDENTITY" "$DMG"
echo "Packed $DMG ($(du -h "$DMG" | cut -f1))"
