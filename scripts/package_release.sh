#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Release script — builds a Mimir.dmg other people can install.
#
# Never touches dist/Mimir.app: everything is built under release/.
#
# Environment:
#   MIMIR_VERSION         — version shown to users, e.g. 0.2.0 (required)
#   MIMIR_BUILD           — build number (default: commit count)
#   MIMIR_DEVELOPER_ID    — "Developer ID Application: Your Name (TEAMID)".
#                           Without it the app is ad-hoc signed and Gatekeeper
#                           will block it on other Macs.
#   MIMIR_NOTARY_PROFILE  — notarytool keychain profile, created once with:
#                           xcrun notarytool store-credentials mimir-notary \
#                             --apple-id <email> --team-id <TEAMID>
#                           Without it the DMG is signed but not notarized.
#
# Output: release/Mimir-<version>.dmg
# -----------------------------------------------------------------------------

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${MIMIR_VERSION:?Set MIMIR_VERSION, e.g. MIMIR_VERSION=0.2.0}"
BUILD="${MIMIR_BUILD:-$(git -C "$ROOT" rev-list --count HEAD)}"
IDENTITY="${MIMIR_DEVELOPER_ID:-}"
NOTARY_PROFILE="${MIMIR_NOTARY_PROFILE:-}"

RELEASE_DIR="$ROOT/release"
STAGING="$RELEASE_DIR/staging"
APP="$STAGING/Mimir.app"
DMG="$RELEASE_DIR/Mimir-$VERSION.dmg"
ENTITLEMENTS="$ROOT/scripts/Mimir.entitlements"

if [ "$(uname -m)" != "arm64" ]; then
    echo "Build on Apple Silicon: Mimir ships arm64 only." >&2
    exit 1
fi

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"

echo "→ Building Mimir $VERSION ($BUILD)"
MIMIR_SKIP_CODESIGN=1 \
MIMIR_OUTPUT_DIR="$STAGING" \
MIMIR_VERSION="$VERSION" \
MIMIR_BUILD="$BUILD" \
    bash "$ROOT/scripts/build_app.sh"

if [ -n "$IDENTITY" ]; then
    echo "→ Signing with $IDENTITY (hardened runtime)"
    # Nested code first: codesign treats the MLX metallib as unsigned code.
    codesign --force --timestamp --sign "$IDENTITY" "$APP/Contents/MacOS/mlx.metallib"
    codesign --force --timestamp --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign "$IDENTITY" "$APP"
    codesign --verify --strict --deep --verbose=2 "$APP"
else
    echo "! MIMIR_DEVELOPER_ID not set: ad-hoc signing. Other Macs must use "Open Anyway" (not notarized)." >&2
    codesign --force --deep --sign - "$APP"
fi

echo "→ Creating $DMG"
ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -volname "Mimir" -srcfolder "$STAGING" -ov -format UDZO "$DMG"

if [ -n "$IDENTITY" ]; then
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
    if [ -n "$NOTARY_PROFILE" ]; then
        echo "→ Notarizing (this takes a few minutes)"
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
        spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
    else
        echo "! MIMIR_NOTARY_PROFILE not set: signed but not notarized. Gatekeeper will still warn." >&2
    fi
fi

rm -rf "$STAGING"
echo "$DMG"
