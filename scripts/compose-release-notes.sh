#!/bin/bash
# Writes a release's full notes: what's new from ReleaseNotes/<version>.md, then how to install it
# and the installers' SHA-256. scripts/make-update-info.sh takes the part before "## 安装" for the
# update window.
# Usage: scripts/compose-release-notes.sh <version> <output.md>
#   (after scripts/package-dmg.sh and scripts/package-pkg.sh)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${1:?usage: scripts/compose-release-notes.sh <version> <output.md>}"
OUTPUT="${2:?usage: scripts/compose-release-notes.sh <version> <output.md>}"
NOTES="ReleaseNotes/$VERSION.md"
PKG="build/PixSnap-$VERSION.pkg"
DMG="build/PixSnap-$VERSION.dmg"
for file in "$NOTES" "$PKG" "$DMG"; do
    [ -f "$file" ] || { echo "No $file" >&2; exit 1; }
done
PKG_SHA="$(shasum -a 256 "$PKG" | cut -d' ' -f1)"
DMG_SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"

cat > "$OUTPUT" <<NOTES
支持 Apple 芯片和 Intel，需要 macOS 14 或更新版本（截图翻译和录制麦克风需要 macOS 15）。

$(cat "$NOTES")

## 安装

已经装了 0.4.0 或更新版本的话，PixSnap 会自动提示更新，点“下载并安装”就行，装好后会自动重新打开。也可以手动安装，两种安装包任选一个，可以直接覆盖旧版本：

- **PixSnap-$VERSION.pkg**（推荐）：双击用系统“安装器”打开，按“继续”一步步装，需要输入一次电脑密码。
- **PixSnap-$VERSION.dmg**：打开后把 PixSnap 拖进“应用程序”，替换旧的。

这一版没有经过 Apple 公证，手动下载的安装包第一次打开时会提示无法验证开发者：到“系统设置 › 隐私与安全性”，在底部点“仍要打开”。

SHA-256：
- \`PixSnap-$VERSION.pkg\`：\`$PKG_SHA\`
- \`PixSnap-$VERSION.dmg\`：\`$DMG_SHA\`

🤖 Generated with [Claude Code](https://claude.com/claude-code)
NOTES
echo "Wrote $OUTPUT"
