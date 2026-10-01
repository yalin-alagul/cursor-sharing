#!/usr/bin/env bash
#
# Build SideCursor.app (via build_macos_app.sh) and pack it into
# dist/SideCursor-macOS.dmg with an Applications shortcut. Used by the release
# workflow. The DMG name is fixed so that
#   https://github.com/<owner>/<repo>/releases/latest/download/SideCursor-macOS.dmg
# always resolves to the newest release.
#
# The app is ad-hoc signed unless a signing identity is available (see
# build_macos_app.sh), so macOS shows a first-launch warning.
#
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
APP_DIR="$ROOT_DIR/dist/SideCursor.app"
STAGE="$ROOT_DIR/dist/dmg"
DMG="$ROOT_DIR/dist/SideCursor-macOS.dmg"

"$ROOT_DIR/tools/build_macos_app.sh"

[ -d "$APP_DIR" ] || { echo "error: $APP_DIR was not produced" >&2; exit 1; }
codesign --verify --deep --strict "$APP_DIR"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP_DIR" "$STAGE/SideCursor.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "SideCursor" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
