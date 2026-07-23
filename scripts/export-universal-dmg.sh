#!/usr/bin/env bash
set -euo pipefail

PROJECT="DiskSense.xcodeproj"
SCHEME="DiskSense"
CONFIGURATION="Release"
APP_NAME="DiskSense"
BUNDLE_ID="com.zyb.DiskSense"
VERSION="${VERSION:-1.0.0}"
BUILD_DIR="${BUILD_DIR:-build/universal}"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DMG_DIR="$BUILD_DIR/dmg"
APP_PATH="$EXPORT_DIR/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/${APP_NAME}-${VERSION}-universal.dmg"

rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR" "$DMG_DIR"
mkdir -p "$BUILD_DIR" "$EXPORT_DIR" "$DMG_DIR"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  SKIP_INSTALL=NO \
  CODE_SIGN_STYLE=Automatic \
  archive

APP_ARCHIVE_PATH="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
if [[ ! -d "$APP_ARCHIVE_PATH" ]]; then
  echo "Archived app not found: $APP_ARCHIVE_PATH" >&2
  exit 1
fi

cp -R "$APP_ARCHIVE_PATH" "$APP_PATH"

if [[ -d "$APP_PATH/Contents/MacOS" ]]; then
  BIN_PATH="$APP_PATH/Contents/MacOS/$APP_NAME"
  if [[ -f "$BIN_PATH" ]]; then
    echo "Built architectures:"
    lipo -info "$BIN_PATH"
  fi
fi

ln -s /Applications "$DMG_DIR/Applications"
cp -R "$APP_PATH" "$DMG_DIR/$APP_NAME.app"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "\nUniversal app: $APP_PATH"
echo "Universal dmg: $DMG_PATH"
