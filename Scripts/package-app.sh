#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")"/.. && pwd)
PRODUCT_NAME="Open Deployment Menu Bar"
EXECUTABLE_NAME="open-deployment-menu-bar"
BUILD_DIR="$ROOT/.build/release"
EXECUTABLE="$BUILD_DIR/$EXECUTABLE_NAME"
APP_DIR="$ROOT/build/${PRODUCT_NAME}.app"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cat > "$APP_DIR/Contents/Info.plist" <<'INFO'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>Open Deployment Menu Bar</string>
    <key>CFBundleExecutable</key>
    <string>open-deployment-menu-bar</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.1orzero.open-deployment-menu-bar</string>
    <key>CFBundleName</key>
    <string>Open Deployment Menu Bar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
INFO

cp "$EXECUTABLE" "$APP_DIR/Contents/MacOS/"
chmod +x "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"

# Copy app icon if it exists
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/"
fi

ENTITLEMENTS="$ROOT/Resources/entitlements.plist"

if [ -n "${SIGNING_IDENTITY:-}" ]; then
    echo "Signing app with identity: $SIGNING_IDENTITY"
    codesign --force --deep --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGNING_IDENTITY" \
        --timestamp \
        "$APP_DIR"
else
    echo "SIGNING_IDENTITY not set: signing ad-hoc"
    codesign --force --deep \
        --entitlements "$ENTITLEMENTS" \
        --sign - \
        "$APP_DIR"
fi

# Verify the signature
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

printf 'App bundle created at %s\n' "$APP_DIR"

# Ad-hoc signed apps cannot be notarized
if [ -z "${SIGNING_IDENTITY:-}" ]; then
    echo "Notarization skipped: app is ad-hoc signed"
    exit 0
fi

# Notarize the app (if credentials are configured)
"$ROOT/Scripts/notarize-app.sh"
