#!/usr/bin/env bash
set -euo pipefail

PROJECT="CleanMac.xcodeproj"
SCHEME="CleanMac"
CONFIGURATION="Release"
APP_NAME="CleanMac"
BUNDLE_ID="com.zyb.CleanMac"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
MINIMUM_SYSTEM_VERSION="${MINIMUM_SYSTEM_VERSION:-13.0}"
SITE_BASE_URL="${SITE_BASE_URL:-https://ruwin985.github.io/CleanMac}"
RELEASE_NOTES_URL="${RELEASE_NOTES_URL:-$SITE_BASE_URL/changelog/}"
RELEASE_SUMMARY="${RELEASE_SUMMARY:-CleanMac $VERSION 更新已发布，建议下载最新版本以获得最新修复和体验优化。}"
UPDATE_CRITICAL="${UPDATE_CRITICAL:-false}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
BUILD_DIR="${BUILD_DIR:-build/universal}"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DMG_DIR="$BUILD_DIR/dmg"
EXPORT_OPTIONS_PATH="$BUILD_DIR/ExportOptions.plist"
APP_PATH="$EXPORT_DIR/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/${APP_NAME}-${VERSION}.dmg"

rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR" "$DMG_DIR"
mkdir -p "$BUILD_DIR" "$EXPORT_DIR" "$DMG_DIR"

DEVELOPER_ID_IDENTITY=""
if [[ -n "$DEVELOPMENT_TEAM" ]]; then
  DEVELOPER_ID_IDENTITY="$(security find-identity -v -p codesigning | awk -v team="$DEVELOPMENT_TEAM" '$0 ~ "Developer ID Application:" && $0 ~ "\\(" team "\\)" { print $2; exit }')"
  if [[ -z "$DEVELOPER_ID_IDENTITY" ]]; then
    echo "Developer ID Application certificate not found for team: $DEVELOPMENT_TEAM" >&2
    echo "Create it in Xcode Settings > Accounts > Manage Certificates, then retry." >&2
    exit 1
  fi
fi

ARCHIVE_ARGS=(
  xcodebuild
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
)

if [[ -n "$DEVELOPMENT_TEAM" ]]; then
  ARCHIVE_ARGS+=(
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY="Developer ID Application"
    ENABLE_HARDENED_RUNTIME=YES
    OTHER_CODE_SIGN_FLAGS="--timestamp"
  )
else
  ARCHIVE_ARGS+=(CODE_SIGN_STYLE=Automatic)
fi

ARCHIVE_ARGS+=(archive)
"${ARCHIVE_ARGS[@]}"

APP_ARCHIVE_PATH="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
if [[ ! -d "$APP_ARCHIVE_PATH" ]]; then
  echo "Archived app not found: $APP_ARCHIVE_PATH" >&2
  exit 1
fi

if [[ -n "$DEVELOPMENT_TEAM" ]]; then
  cat > "$EXPORT_OPTIONS_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>signingCertificate</key>
  <string>Developer ID Application</string>
  <key>teamID</key>
  <string>$DEVELOPMENT_TEAM</string>
  <key>stripSwiftSymbols</key>
  <true/>
</dict>
</plist>
EOF

  xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PATH"
else
  cp -R "$APP_ARCHIVE_PATH" "$APP_PATH"
fi

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

if [[ -n "$DEVELOPER_ID_IDENTITY" ]]; then
  codesign --force --sign "$DEVELOPER_ID_IDENTITY" --timestamp "$DMG_PATH"
fi

if [[ -n "$NOTARY_PROFILE" ]]; then
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
fi

SITE_DOWNLOADS_DIR="site/static/downloads"
mkdir -p "$SITE_DOWNLOADS_DIR"
cp -f "$DMG_PATH" "$SITE_DOWNLOADS_DIR/$APP_NAME.dmg"

SITE_UPDATES_DIR="site/static/updates"
UPDATE_MANIFEST_PATH="$SITE_UPDATES_DIR/cleanmac.json"
PUBLISHED_AT="${PUBLISHED_AT:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"
mkdir -p "$SITE_UPDATES_DIR"

export VERSION BUILD_NUMBER MINIMUM_SYSTEM_VERSION SITE_BASE_URL RELEASE_NOTES_URL RELEASE_SUMMARY UPDATE_CRITICAL PUBLISHED_AT UPDATE_MANIFEST_PATH
python3 <<'PY'
import json
import os
from pathlib import Path

site_base_url = os.environ["SITE_BASE_URL"].rstrip("/")
manifest = {
    "version": os.environ["VERSION"],
    "build": int(os.environ["BUILD_NUMBER"]),
    "minimumSystemVersion": os.environ["MINIMUM_SYSTEM_VERSION"],
    "downloadURL": f"{site_base_url}/downloads/CleanMac.dmg",
    "releaseNotesURL": os.environ["RELEASE_NOTES_URL"],
    "title": f"CleanMac {os.environ['VERSION']} 已发布",
    "summary": os.environ["RELEASE_SUMMARY"],
    "isCritical": os.environ["UPDATE_CRITICAL"].lower() == "true",
    "publishedAt": os.environ["PUBLISHED_AT"],
}

path = Path(os.environ["UPDATE_MANIFEST_PATH"])
path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

echo "\nUniversal app: $APP_PATH"
echo "Universal dmg: $DMG_PATH"
echo "Site download: $SITE_DOWNLOADS_DIR/$APP_NAME.dmg"
echo "Update manifest: $UPDATE_MANIFEST_PATH"
