#!/usr/bin/env bash
#
# Build, sign, notarize, and package SoloDisplay.app for distribution.
#
# Produces a stapled, notarized SoloDisplay.app plus a .zip and .dmg (with .sha256
# sidecars) under build/dist/. Works both locally (Keychain notary profile) and
# in CI (App Store Connect API key). See docs/DISTRIBUTION.md for setup.
#
# Usage:
#   VERSION=0.1.0 scripts/build-release.sh
#
# Required env:
#   VERSION              Marketing version, e.g. 0.1.0 (injected at build time).
#   DEVELOPMENT_TEAM     Apple Developer Team ID (10 chars).
#
# Signing identity (default: "Developer ID Application"):
#   SIGN_IDENTITY        Full identity name or hash.
#
# Notarization credentials (pick ONE; skipped entirely with --skip-notarize):
#   Local:  NOTARY_PROFILE   Name of a `notarytool store-credentials` profile.
#   CI:     AC_API_KEY_ID, AC_API_ISSUER_ID, AC_API_KEY_PATH (path to .p8)
#
# Options:
#   --skip-notarize      Build + sign only (dry run; no Apple round-trip).
#
set -euo pipefail

cd "$(dirname "$0")/.."

SKIP_NOTARIZE=0
[[ "${1:-}" == "--skip-notarize" ]] && SKIP_NOTARIZE=1

VERSION="${VERSION:?set VERSION, e.g. VERSION=0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM (Apple Team ID)}"

PROJECT="SoloDisplay.xcodeproj"
SCHEME="SoloDisplay"
APP="SoloDisplay.app"
BUILD_DIR="build"
ARCHIVE="$BUILD_DIR/SoloDisplay.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DIST_DIR="$BUILD_DIR/dist"
ZIP="$DIST_DIR/SoloDisplay-$VERSION.zip"
DMG="$DIST_DIR/SoloDisplay-$VERSION.dmg"

echo ">> Cleaning $BUILD_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$EXPORT_DIR" "$DIST_DIR"

echo ">> Archiving $SCHEME ($VERSION build $BUILD_NUMBER)"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime"

cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$DEVELOPMENT_TEAM</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>$SIGN_IDENTITY</string>
</dict>
</plist>
PLIST

echo ">> Exporting Developer ID app"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist"

APP_PATH="$EXPORT_DIR/$APP"
echo ">> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

if [[ "$SKIP_NOTARIZE" == "1" ]]; then
  echo ">> --skip-notarize set: stopping after sign. App at $APP_PATH"
  exit 0
fi

# --- Notarize ---
NOTARY_ARGS=()
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${AC_API_KEY_ID:-}" ]]; then
  NOTARY_ARGS=(--key "${AC_API_KEY_PATH:?set AC_API_KEY_PATH}" \
               --key-id "$AC_API_KEY_ID" \
               --issuer "${AC_API_ISSUER_ID:?set AC_API_ISSUER_ID}")
else
  echo "!! No notary credentials (set NOTARY_PROFILE or AC_API_* )." >&2
  exit 1
fi

echo ">> Submitting to notary service (this can take a few minutes)"
ditto -c -k --keepParent "$APP_PATH" "$BUILD_DIR/notarize.zip"
xcrun notarytool submit "$BUILD_DIR/notarize.zip" "${NOTARY_ARGS[@]}" --wait

echo ">> Stapling ticket"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl -a -vvv --type exec "$APP_PATH" || true

# --- Package ---
echo ">> Packaging .zip"
ditto -c -k --keepParent "$APP_PATH" "$ZIP"

echo ">> Packaging .dmg"
if command -v create-dmg >/dev/null 2>&1; then
  create-dmg --volname "SoloDisplay $VERSION" --app-drop-link 480 170 \
    --icon "$APP" 160 170 --window-size 640 360 \
    "$DMG" "$APP_PATH" >/dev/null
else
  # Fallback: plain read-only dmg from a staging folder.
  STAGE="$BUILD_DIR/dmg-stage"
  mkdir -p "$STAGE"
  cp -R "$APP_PATH" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "SoloDisplay $VERSION" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG" >/dev/null
fi

echo ">> Checksums"
for f in "$ZIP" "$DMG"; do
  shasum -a 256 "$f" | tee "$f.sha256"
done

echo ">> Done. Artifacts in $DIST_DIR"
