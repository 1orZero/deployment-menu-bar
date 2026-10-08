#!/usr/bin/env bash
# Builds "Open Deployment Menu Bar.app" with Xcode and signs it with the team in project.yml.
# The app needs a provisioning profile for its iCloud Keychain access group, so it is archived and exported with
# automatic signing instead of being signed by hand.
#
#   ./Scripts/package-app.sh                              # Apple Development, runs on Macs registered to the team
#   EXPORT_METHOD=developer-id ./Scripts/package-app.sh   # Developer ID, then notarization (Scripts/notarize-app.sh)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")"/.. && pwd)
PRODUCT_NAME="Open Deployment Menu Bar"
EXPORT_METHOD=${EXPORT_METHOD:-debugging}
WORK_DIR="$ROOT/.build/package"
ARCHIVE_PATH="$WORK_DIR/OpenDeploymentMenuBar.xcarchive"
OUTPUT_DIR="$ROOT/build"
APP_DIR="$OUTPUT_DIR/${PRODUCT_NAME}.app"

cd "$ROOT"
xcodegen generate --quiet

rm -rf "$WORK_DIR" "$APP_DIR"
mkdir -p "$WORK_DIR" "$OUTPUT_DIR"

xcodebuild \
    -project OpenDeployment.xcodeproj \
    -scheme OpenDeploymentMenuBar \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -allowProvisioningUpdates \
    archive

cat > "$WORK_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>${EXPORT_METHOD}</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST

xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$WORK_DIR/export" \
    -exportOptionsPlist "$WORK_DIR/ExportOptions.plist" \
    -allowProvisioningUpdates

ditto "$WORK_DIR/export/${PRODUCT_NAME}.app" "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
printf 'App bundle created at %s\n' "$APP_DIR"

if [ "$EXPORT_METHOD" = "developer-id" ]; then
    "$ROOT/Scripts/notarize-app.sh"
else
    echo "Notarization skipped: exported with method '$EXPORT_METHOD' (only developer-id builds are notarized)"
fi
