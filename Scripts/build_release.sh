#!/bin/bash
set -euo pipefail

# Build a development-signed NerLan.ipa for GitHub releases.
# Usage: bash Scripts/build_release.sh
#
# Output: .build/export/NerLan.ipa

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="NerLan"
TEAM_ID="3WD42GF27D"
BUILD_DIR="$PROJECT_DIR/.build"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"

cd "$PROJECT_DIR"

echo "==> Generating Xcode project..."
xcodegen generate

echo "==> Archiving (Release, generic iOS device)..."
rm -rf "$ARCHIVE_PATH"
xcodebuild archive \
    -project "$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE_PATH" \
    -allowProvisioningUpdates

echo "==> Writing export options (development signing)..."
mkdir -p "$BUILD_DIR"
cat > "$EXPORT_OPTIONS" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>debugging</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>compileBitcode</key>
    <false/>
</dict>
</plist>
PLIST

echo "==> Exporting .ipa..."
rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -allowProvisioningUpdates

echo ""
echo "==> Done! IPA exported at:"
echo "    $EXPORT_DIR/$APP_NAME.ipa ($(du -h "$EXPORT_DIR/$APP_NAME.ipa" | cut -f1))"
echo ""
echo "    Note: this ipa is development-signed. It installs only on devices"
echo "    registered to team $TEAM_ID (via Xcode or Apple Configurator)."
