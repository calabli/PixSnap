#!/bin/bash
# Builds a release PixSnap.app (Apple silicon + Intel) and wraps it in an installer package,
# build/PixSnap-<version>.pkg, which macOS's Installer opens with welcome and finish pages and
# a progress bar, and which puts PixSnap in /Applications.
# Usage: scripts/package-pkg.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
scripts/build-app.sh release

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
PKG="$ROOT/build/PixSnap-$VERSION.pkg"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/root" "$WORK/resources"
cp -R build/PixSnap.app "$WORK/root/"
cp Resources/Installer/*.html "$WORK/resources/"

# Not relocatable: otherwise Installer would update whatever copy of PixSnap it finds on the
# Mac (a build folder, say) instead of the one in /Applications.
pkgbuild --analyze --root "$WORK/root" "$WORK/components.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Add :0:BundleIsRelocatable bool false" "$WORK/components.plist"
# The postinstall script opens PixSnap again once it's in place (after an update, too).
pkgbuild --root "$WORK/root" --component-plist "$WORK/components.plist" --install-location /Applications \
    --scripts Resources/Installer/scripts \
    --identifier com.pixsnap.PixSnap.app --version "$VERSION" "$WORK/PixSnap-app.pkg" >/dev/null

cat > "$WORK/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>PixSnap $VERSION</title>
    <welcome file="welcome.html" mime-type="text/html"/>
    <conclusion file="conclusion.html" mime-type="text/html"/>
    <options customize="never" require-scripts="true" hostArchitectures="arm64,x86_64"/>
    <domains enable_localSystem="true"/>
    <volume-check>
        <allowed-os-versions><os-version min="14.0"/></allowed-os-versions>
    </volume-check>
    <choices-outline><line choice="default"/></choices-outline>
    <choice id="default" title="PixSnap"><pkg-ref id="com.pixsnap.PixSnap.app"/></choice>
    <pkg-ref id="com.pixsnap.PixSnap.app" version="$VERSION" onConclusion="none">PixSnap-app.pkg</pkg-ref>
</installer-gui-script>
XML

# Signed when a "Developer ID Installer" certificate is in the keychain; unsigned otherwise.
IDENTITY="${PIXSNAP_INSTALLER_IDENTITY:-$(security find-identity -v | awk -F'"' '/Developer ID Installer/ {print $2; exit}')}"
productbuild --distribution "$WORK/distribution.xml" --resources "$WORK/resources" --package-path "$WORK" \
    ${IDENTITY:+--sign "$IDENTITY"} "$PKG" >/dev/null
echo "Packed $PKG ($(du -h "$PKG" | cut -f1), ${IDENTITY:+signed with $IDENTITY}${IDENTITY:-unsigned})"
