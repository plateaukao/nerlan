#!/bin/bash
set -euo pipefail

# Build NerLan for "Mac (Designed for iPad)" and run it natively on this Apple
# Silicon Mac.
#
# The iOS app bundle can't be launched directly with `open` (it's a platform-iOS
# binary — "incorrect executable format"); macOS runs it through a wrapper bundle,
# the same structure the App Store uses for "iPhone & iPad apps on Mac". This
# script builds, wraps, and launches it.
#
# Usage:
#   bash Scripts/run_mac.sh            build + wrap + launch
#   LAUNCH=0 bash Scripts/run_mac.sh   build + wrap only (used by build_mac_dmg.sh)
#
# Requires an Apple Silicon Mac. Output wrapper: .build/mac/NerLan.app

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="NerLan"
BUILD_DIR="$PROJECT_DIR/.build"
WRAP_DIR="$BUILD_DIR/mac"
WRAP="$WRAP_DIR/$APP_NAME.app"
DEST='platform=macOS,variant=Designed for iPad'

cd "$PROJECT_DIR"

echo "==> Generating Xcode project..."
xcodegen generate >/dev/null

echo "==> Building for Mac (Designed for iPad)..."
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
    -destination "$DEST" -allowProvisioningUpdates build

echo "==> Locating built app..."
SETTINGS=$(xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
    -destination "$DEST" -showBuildSettings 2>/dev/null)
BUILT_DIR=$(echo "$SETTINGS" | awk -F' = ' '/ TARGET_BUILD_DIR = /{print $2; exit}')
WRAPPER_NAME=$(echo "$SETTINGS" | awk -F' = ' '/ WRAPPER_NAME = /{print $2; exit}')
APP_PATH="$BUILT_DIR/$WRAPPER_NAME"
[ -d "$APP_PATH" ] || { echo "error: built app not found at $APP_PATH" >&2; exit 1; }

echo "==> Wrapping into a Mac-runnable bundle..."
rm -rf "$WRAP_DIR"
mkdir -p "$WRAP/Wrapper"
cp -R "$APP_PATH" "$WRAP/Wrapper/$APP_NAME.app"
ln -s "Wrapper/$APP_NAME.app" "$WRAP/WrappedBundle"

echo "==> Done: $WRAP"
if [ "${LAUNCH:-1}" = "1" ]; then
    echo "==> Launching..."
    open "$WRAP"
fi
