#!/bin/bash
set -euo pipefail

# Build a notarized, Developer ID-signed Mac (Catalyst) NerLan.dmg that runs on any
# Mac, Gatekeeper-clean. Mirrors ../whisperASR/Scripts/release.sh, adapted for a
# Mac Catalyst archive.
#
# One-time prerequisites:
#   - "Developer ID Application" certificate in the login keychain (team 3WD42GF27D)
#   - a notarytool keychain profile named "notarytool":
#       xcrun notarytool store-credentials notarytool \
#           --apple-id <apple-id> --team-id 3WD42GF27D --password <app-specific-password>
#
# Usage: bash Scripts/release_mac.sh
# Output: .build/NerLan.dmg (notarized + stapled)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="NerLan"
TEAM_ID="3WD42GF27D"
KEYCHAIN_PROFILE="notarytool"
BUILD_DIR="$PROJECT_DIR/.build"
ARCHIVE="$BUILD_DIR/$APP_NAME-maccatalyst.xcarchive"
EXPORT_DIR="$BUILD_DIR/export-mac"
EXPORT_OPTIONS="$BUILD_DIR/ExportOptionsMac.plist"
APP="$EXPORT_DIR/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"

cd "$PROJECT_DIR"

echo "==> Generating Xcode project..."
xcodegen generate >/dev/null

echo "==> Archiving (Mac Catalyst, Release)..."
rm -rf "$ARCHIVE"
xcodebuild archive \
    -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
    -destination 'generic/platform=macOS,variant=Mac Catalyst' \
    -archivePath "$ARCHIVE" -allowProvisioningUpdates

echo "==> Writing export options (Developer ID)..."
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST

echo "==> Exporting Developer ID-signed app..."
rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS" -allowProvisioningUpdates

echo "==> Notarizing (submitting to Apple; this may take a few minutes)..."
ZIP="$BUILD_DIR/$APP_NAME-mac.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$KEYCHAIN_PROFILE" --wait
rm -f "$ZIP"

echo "==> Stapling the notarization ticket..."
xcrun stapler staple "$APP"

echo "==> Building DMG..."
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$STAGING"

echo "==> Done: $DMG_PATH (notarized + stapled)"
echo "    Runs on any Mac, Gatekeeper-clean. Open it and drag NerLan into Applications."
