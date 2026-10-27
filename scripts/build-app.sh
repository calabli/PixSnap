#!/bin/bash
# Builds PixSnap with SwiftPM and wraps the binary into build/PixSnap.app.
# Usage: scripts/build-app.sh [debug|release] [--run]
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/PixSnap.app"

cd "$ROOT"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PixSnap" "$APP/Contents/MacOS/PixSnap"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# A stable signing identity keeps the Screen Recording permission across rebuilds.
# Falls back to ad-hoc signing ("-"), which makes macOS ask for permission again after every build.
IDENTITY="${PIXSNAP_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed with: ${IDENTITY:-ad-hoc})"

if [[ "${2:-}" == "--run" ]]; then
    pkill -x PixSnap 2>/dev/null || true
    # Opening while the old instance is still shutting down fails with LaunchServices error -600.
    for _ in {1..30}; do
        pgrep -x PixSnap >/dev/null || break
        sleep 0.1
    done
    open "$APP"
fi
