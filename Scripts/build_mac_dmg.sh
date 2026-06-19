#!/bin/bash
set -euo pipefail

# Package NerLan as a Mac .dmg (drag-to-Applications) from the "Designed for iPad"
# build.
#
# The DMG installs and runs on THIS Mac and on Macs that trust your developer
# certificate. NOTE: Apple does not support notarizing "Designed for iPad" apps for
# distribution outside the Mac App Store, so this DMG is for personal/local install.
# For a notarized, broadly distributable Mac app, build with Mac Catalyst instead
# (then sign with Developer ID + notarytool, like ../whisperASR/Scripts/release.sh).
#
# Optional: set CODESIGN_IDENTITY to sign the wrapper (e.g. "Apple Development: …"
# or "Developer ID Application: …").
#
# Usage: bash Scripts/build_mac_dmg.sh
# Output: .build/NerLan.dmg

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="NerLan"
BUILD_DIR="$PROJECT_DIR/.build"
WRAP="$BUILD_DIR/mac/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"

# Build + wrap (no launch) by reusing run_mac.sh.
LAUNCH=0 bash "$SCRIPT_DIR/run_mac.sh"
[ -d "$WRAP" ] || { echo "error: wrapper not found at $WRAP" >&2; exit 1; }

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    echo "==> Signing wrapper with: $CODESIGN_IDENTITY"
    codesign --force --deep --sign "$CODESIGN_IDENTITY" "$WRAP"
fi

echo "==> Building DMG..."
STAGING="$(mktemp -d)"
cp -R "$WRAP" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$STAGING"

echo "==> Done: $DMG_PATH"
echo "    Open it, then drag NerLan into Applications."
