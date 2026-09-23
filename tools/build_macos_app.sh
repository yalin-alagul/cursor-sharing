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
cp "$PACKAGE_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

# A stable signing identity keeps the app's code requirement constant, so the
# macOS Accessibility/Input Monitoring grant survives rebuilds.  Ad-hoc signing
# derives its requirement from the binary hash and silently invalidates the
# grant on every build.  Override with SIDECURSOR_SIGN_IDENTITY; fall back to
# ad-hoc only when no identity is available.
SIGN_IDENTITY="${SIDECURSOR_SIGN_IDENTITY:-SideCursor Local Signing}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$SIGN_IDENTITY\""; then
    codesign --force --timestamp=none --sign "$SIGN_IDENTITY" "$APP_DIR"
    echo "Signed with '$SIGN_IDENTITY'"
else
    codesign --force --sign - "$APP_DIR"
    echo "WARNING: no signing identity '$SIGN_IDENTITY' found; used ad-hoc signing." >&2
    echo "Create one (see README) or the macOS permission grant must be re-approved after every build." >&2
fi
echo "Built $APP_DIR"
