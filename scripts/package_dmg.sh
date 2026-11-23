#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/Resources/Info.plist")
VERSION="${1:-$PLIST_VERSION}"
APP_BUNDLE="$ROOT/build/Lumi.app"
DIST_DIR="$ROOT/dist"
STAGING="$ROOT/build/dmg_stage"
DMG_PATH="$DIST_DIR/Lumi-v${VERSION}-arm64.dmg"

if [ "$VERSION" != "$PLIST_VERSION" ]; then
    echo "Error: Requested DMG version ($VERSION) does not match Resources/Info.plist CFBundleShortVersionString ($PLIST_VERSION)." >&2
    exit 1
fi

if [ "${LUMI_SKIP_BUILD:-0}" != "1" ] || [ ! -d "$APP_BUNDLE" ]; then
    "$ROOT/scripts/build_app.sh"
fi

BUNDLE_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_BUNDLE/Contents/Info.plist")
if [ "$BUNDLE_VERSION" != "$VERSION" ]; then
    echo "Error: Built bundle version ($BUNDLE_VERSION) does not match target version ($VERSION)." >&2
    exit 1
fi

ARCHS=$(lipo -archs "$APP_BUNDLE/Contents/MacOS/Lumi")
if ! echo "$ARCHS" | grep -qw "arm64"; then
    echo "Error: Expected arm64 binary in $APP_BUNDLE, got: $ARCHS" >&2
    exit 1
fi

echo "==> Verifying app bundle signature..."
codesign --verify --deep --strict "$APP_BUNDLE"

SIGN_ID="${LUMI_SIGN_IDENTITY:-}"
if [ -z "$SIGN_ID" ]; then
    SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Developer ID Application" | sed -E 's/.*"([^"]+)".*/\1/' || true)
fi

if [ -n "${LUMI_NOTARY_PROFILE:-}" ]; then
    if [ -z "$SIGN_ID" ]; then
        echo "Error: LUMI_NOTARY_PROFILE is set, but no Developer ID Application signing identity was found." >&2
        exit 1
    fi
    CODESIGN_INFO=$(codesign -dvv "$APP_BUNDLE" 2>&1)
    if ! grep -q "Authority=Developer ID Application:" <<< "$CODESIGN_INFO"; then
        echo "Error: $APP_BUNDLE is not signed with a Developer ID Application certificate." >&2
        exit 1
    fi
fi

rm -rf "$STAGING" "$DMG_PATH"
mkdir -p "$STAGING" "$DIST_DIR"
cp -R "$APP_BUNDLE" "$STAGING/Lumi.app"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "Lumi" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH"

if [ -n "$SIGN_ID" ]; then
    echo "==> Signing $DMG_PATH with $SIGN_ID..."
    codesign --force --timestamp --sign "$SIGN_ID" "$DMG_PATH"
fi

# Apple Notarization for public distribution:
#   LUMI_NOTARY_PROFILE="lumi-notary" ./scripts/package_dmg.sh 1.4.0
if [ -n "${LUMI_NOTARY_PROFILE:-}" ]; then
    echo "==> Submitting $DMG_PATH for Apple Notarization (profile: $LUMI_NOTARY_PROFILE)..."
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$LUMI_NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
    spctl --assess -vv --type open --context context:primary-signature "$DMG_PATH"
    echo "==> Notarization, stapling, and Gatekeeper validation succeeded!"
fi

SHA=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')

echo ""
echo "==> DMG ready: $DMG_PATH"
echo "==> Version:   $VERSION ($ARCHS)"
echo "==> SHA256:    $SHA"
