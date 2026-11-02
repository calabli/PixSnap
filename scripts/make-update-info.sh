#!/bin/bash
# Writes build/latest.json for the release about to be published: the version, what's new, and
# where the installer is with its SHA-256 and size. Installed copies of PixSnap read it from the
# newest release (releases/latest/download/latest.json) to offer the update, so it goes up with
# every release next to the .pkg and .dmg.
# Usage: scripts/make-update-info.sh <release-notes.md>
#   (after scripts/package-pkg.sh; only the notes before "## 安装" are used)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
NOTES="${1:?usage: scripts/make-update-info.sh <release-notes.md>}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
MINIMUM="$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' Resources/Info.plist)"
PKG="build/PixSnap-$VERSION.pkg"
[ -f "$PKG" ] || { echo "No $PKG: run scripts/package-pkg.sh first" >&2; exit 1; }

SHA="$(shasum -a 256 "$PKG" | cut -d' ' -f1)"
SIZE="$(stat -f %z "$PKG")"
URL="https://github.com/calabli/PixSnap/releases/download/v$VERSION/PixSnap-$VERSION.pkg"

/usr/bin/python3 -I - "$NOTES" "$VERSION" "$URL" "$SHA" "$SIZE" "$MINIMUM" build/latest.json <<'PY'
import json, sys
notes_path, version, url, sha, size, minimum, out = sys.argv[1:]
lines = open(notes_path, encoding="utf-8").read().split("\n")
kept = []
for line in lines:
    if line.startswith("## 安装"):
        break
    kept.append(line)
info = {"version": version, "notes": "\n".join(kept).strip(), "url": url, "sha256": sha, "size": int(size),
        "minimumSystemVersion": minimum}
with open(out, "w", encoding="utf-8") as f:
    json.dump(info, f, ensure_ascii=False, indent=2)
PY
echo "Wrote build/latest.json for $VERSION"
