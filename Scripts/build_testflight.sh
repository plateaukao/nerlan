#!/bin/bash
set -euo pipefail

# Build and (optionally) upload a TestFlight build of NerLan.
#
# Produces an App Store distribution-signed archive, exports it, and — when an
# App Store Connect API key is provided via env vars — uploads it straight to
# App Store Connect for INTERNAL testing (no Beta App Review needed).
#
# Usage:
#   bash Scripts/build_testflight.sh
#
# Auto-uploads when ALL of these are set (App Store Connect API key):
#   ASC_KEY_ID     - the key's Key ID (e.g. ABC123XYZ9)
#   ASC_ISSUER_ID  - the Issuer ID (UUID; App Store Connect ->
#                    Users and Access -> Integrations -> App Store Connect API)
#   ASC_KEY_PATH   - absolute path to the AuthKey_XXXXXXXXXX.p8 file
#
# Without those it stops after producing the .ipa and prints how to upload it
# (Transporter.app, or the altool command shown).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="NerLan"
TEAM_ID="3WD42GF27D"
BUILD_DIR="$PROJECT_DIR/.build"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/testflight"
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions-AppStore.plist"

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

# Upload directly only when a full API key is provided.
UPLOAD=false
if [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" && -n "${ASC_KEY_PATH:-}" ]]; then
    UPLOAD=true
fi

echo "==> Writing export options (App Store distribution, automatic signing)..."
mkdir -p "$BUILD_DIR"
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
  echo '<plist version="1.0">'
  echo '<dict>'
  echo '    <key>method</key>'
  echo '    <string>app-store-connect</string>'
  echo '    <key>teamID</key>'
  echo "    <string>$TEAM_ID</string>"
  echo '    <key>signingStyle</key>'
  echo '    <string>automatic</string>'
  if [[ "$UPLOAD" == true ]]; then
    echo '    <key>destination</key>'
    echo '    <string>upload</string>'
  fi
  echo '</dict>'
  echo '</plist>'
} > "$EXPORT_OPTIONS"

echo "==> Exporting..."
rm -rf "$EXPORT_DIR"
if [[ "$UPLOAD" == true ]]; then
    echo "    (uploading to App Store Connect via API key $ASC_KEY_ID)"
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_DIR" \
        -exportOptionsPlist "$EXPORT_OPTIONS" \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$ASC_KEY_PATH" \
        -authenticationKeyID "$ASC_KEY_ID" \
        -authenticationKeyIssuerID "$ASC_ISSUER_ID"
    echo ""
    echo "==> Uploaded. The build appears in App Store Connect -> TestFlight in a"
    echo "    few minutes once processing finishes. Add yourself as an Internal"
    echo "    Tester to install it over the air."
else
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_DIR" \
        -exportOptionsPlist "$EXPORT_OPTIONS" \
        -allowProvisioningUpdates
    echo ""
    echo "==> Exported (NOT uploaded): $EXPORT_DIR/$APP_NAME.ipa"
    echo "    To upload, either:"
    echo "      - open Transporter.app and drag the .ipa in, or"
    echo "      - set ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH and re-run, or"
    echo "      - xcrun altool --upload-app -f '$EXPORT_DIR/$APP_NAME.ipa' \\"
    echo "            --type ios --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>"
fi
