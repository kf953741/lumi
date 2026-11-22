#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Lumi"
BUILD_DIR="$ROOT/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
INSTALL_APP="/Applications/$APP_NAME.app"

echo "==> Building $APP_NAME (SwiftPM release)..."
cd "$ROOT"
swift build -c release

BIN_PATH="$ROOT/.build/release/$APP_NAME"
if [ ! -x "$BIN_PATH" ]; then
    echo "Error: compiled binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "==> Generating AppIcon.icns..."
ICONSET="$BUILD_DIR/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
swift "$ROOT/scripts/generate_icon.swift" "$BUILD_DIR/AppIcon_1024.png"

for sz in 16 32 128 256 512; do
    sips -z $sz $sz "$BUILD_DIR/AppIcon_1024.png" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
    sz2=$((sz * 2))
    sips -z $sz2 $sz2 "$BUILD_DIR/AppIcon_1024.png" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$BUILD_DIR/AppIcon.icns"

echo "==> Assembling $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$BUILD_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/Hooks/lumi-hook.py" "$APP_BUNDLE/Contents/Resources/lumi-hook.py"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME" "$APP_BUNDLE/Contents/Resources/lumi-hook.py"

echo "==> Signing $APP_BUNDLE..."
SIGN_ID="${LUMI_SIGN_IDENTITY:-}"
if [ -z "$SIGN_ID" ]; then
    SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Developer ID Application" | sed -E 's/.*"([^"]+)".*/\1/' || true)
fi
if [ -z "$SIGN_ID" ]; then
    SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development" | sed -E 's/.*"([^"]+)".*/\1/' || true)
fi
if [ -n "$SIGN_ID" ]; then
    echo "    Using signing identity: $SIGN_ID"
    codesign --force --deep --options runtime --sign "$SIGN_ID" "$APP_BUNDLE"
else
    echo "    Using ad-hoc signature (-)"
    codesign --force --deep --sign - "$APP_BUNDLE"
fi

echo "==> Installing hook script to ~/.lumi/lumi-hook.py..."
mkdir -p "$HOME/.lumi/live"
cp "$ROOT/Resources/Hooks/lumi-hook.py" "$HOME/.lumi/lumi-hook.py"
chmod +x "$HOME/.lumi/lumi-hook.py"

echo "==> Installing to $INSTALL_APP..."
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.3
rm -rf "$INSTALL_APP"
cp -R "$APP_BUNDLE" "$INSTALL_APP"

echo "==> Built & installed $INSTALL_APP successfully!"
