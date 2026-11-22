#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-1.0.0}"
APP_BUNDLE="$ROOT/build/Lumi.app"
DIST_DIR="$ROOT/dist"
STAGING="$ROOT/build/dmg_stage"
DMG_PATH="$DIST_DIR/Lumi-v${VERSION}-arm64.dmg"

if [ ! -d "$APP_BUNDLE" ]; then
    "$ROOT/scripts/build_app.sh"
fi

rm -rf "$STAGING" "$DMG_PATH"
mkdir -p "$STAGING" "$DIST_DIR"
cp -R "$APP_BUNDLE" "$STAGING/Lumi.app"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "Lumi" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH"
SHA=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')

echo ""
echo "==> DMG ready: $DMG_PATH"
echo "==> SHA256:    $SHA"
