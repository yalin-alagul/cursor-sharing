#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
PACKAGE_DIR="$ROOT_DIR/apps/macos"
APP_DIR="$ROOT_DIR/dist/SideCursor.app"
PRODUCT="$PACKAGE_DIR/.build/release/SideCursorMac"

cd "$PACKAGE_DIR"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$PRODUCT" "$APP_DIR/Contents/MacOS/SideCursorMac"
cp "$PACKAGE_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

# This is intentionally ad-hoc signing for the local-first delivery path.
codesign --force --sign - "$APP_DIR"
echo "Built $APP_DIR"
