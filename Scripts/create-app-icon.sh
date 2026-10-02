#!/usr/bin/env bash
# Regenerates the app icon resources:
# - Resources/AppIcon.icns from a 1024x1024 source PNG (CFBundleIconFile fallback).
# - Resources/Assets.car from the Icon Composer bundle Resources/AppIcon.icon (CFBundleIconName).
#   macOS 26+ draws icons that are not system-masked inside a gray squircle; the compiled
#   .icon is masked by the system, so it renders without that frame. Requires Xcode 26+.
# Usage: Scripts/create-app-icon.sh [source.png]   (default: Resources/AppIcon-source.png)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")"/.. && pwd)
SOURCE=${1:-"$ROOT/Resources/AppIcon-source.png"}
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
ICONSET_DIR="$WORK_DIR/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$SOURCE" --out "$ICONSET_DIR/icon_${size}x${size}.png" > /dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$SOURCE" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" > /dev/null
done

iconutil -c icns "$ICONSET_DIR" -o "$ROOT/Resources/AppIcon.icns"
echo "App icon created at $ROOT/Resources/AppIcon.icns"

CATALOG_DIR="$WORK_DIR/catalog"
mkdir -p "$CATALOG_DIR"
xcrun actool "$ROOT/Resources/AppIcon.icon" \
  --compile "$CATALOG_DIR" \
  --app-icon AppIcon \
  --platform macosx \
  --target-device mac \
  --minimum-deployment-target 13.0 \
  --output-partial-info-plist "$CATALOG_DIR/partial-info.plist" \
  --output-format human-readable-text --errors --warnings --notices
install -m 644 "$CATALOG_DIR/Assets.car" "$ROOT/Resources/Assets.car"
echo "Asset catalog created at $ROOT/Resources/Assets.car"
