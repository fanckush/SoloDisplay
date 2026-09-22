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
# Update feed (required unless --skip-notarize):
#   SPARKLE_PRIVATE_KEY  The EdDSA private key from Sparkle's `generate_keys -x`.
#   RELEASE_NOTES        Optional path to Markdown shown in the update window.
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
INFO_PLIST="Config/SoloDisplay-Info.plist"
SCHEME="SoloDisplay"
APP="SoloDisplay.app"
BUILD_DIR="build"
ARCHIVE="$BUILD_DIR/SoloDisplay.xcarchive"
# Resolved packages live here rather than in DerivedData, so Sparkle's tools are at a known path.
PACKAGES_DIR="$BUILD_DIR/SourcePackages"
SIGN_UPDATE="$PACKAGES_DIR/artifacts/sparkle/Sparkle/bin/sign_update"
EXPORT_DIR="$BUILD_DIR/export"
DIST_DIR="$BUILD_DIR/dist"
ZIP="$DIST_DIR/SoloDisplay-$VERSION.zip"
DMG="$DIST_DIR/SoloDisplay-$VERSION.dmg"
# A copy under a name that never changes, so the README can link straight at the newest build.
# GitHub's /releases/latest/download/ redirect resolves an exact asset name, which rules out
# every version-stamped one.
DMG_LATEST="$DIST_DIR/SoloDisplay.dmg"
# Also a fixed name: the app's SUFeedURL points at /releases/latest/download/appcast.xml.
APPCAST="$DIST_DIR/appcast.xml"
REPO_URL="https://github.com/fanckush/SoloDisplay"

# A release the app cannot verify would strand everyone who installs it, so check before the
# long build rather than after.
if [[ "$SKIP_NOTARIZE" == "0" ]]; then
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO_PLIST")" == SPARKLE_* ]]; then
    echo "!! SUPublicEDKey in $INFO_PLIST is not set. See docs/DISTRIBUTION.md." >&2
    exit 1
  fi
  [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]] || {
    echo "!! set SPARKLE_PRIVATE_KEY to sign the update feed." >&2
    exit 1
  }
fi

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
  -clonedSourcePackagesDirPath "$PACKAGES_DIR" \
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

echo ">> Writing $APPCAST"
# Sparkle downloads the zip. Its signature is checked against SUPublicEDKey before anything is
# installed.
ENCLOSURE_SIG=$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - "$ZIP")
NOTES=""
if [[ -n "${RELEASE_NOTES:-}" && -s "$RELEASE_NOTES" ]]; then
  # Markdown goes in as CDATA. A literal ]]> in it would end the section early, so it is split.
  NOTES="<description sparkle:format=\"markdown\"><![CDATA[$(sed 's/]]>/]]]]><![CDATA[>/g' "$RELEASE_NOTES")]]></description>"
fi
cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>SoloDisplay</title>
    <item>
      <title>SoloDisplay $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$REPO_URL/releases</sparkle:fullReleaseNotesLink>
      $NOTES
      <enclosure url="$REPO_URL/releases/download/v$VERSION/$(basename "$ZIP")" $ENCLOSURE_SIG type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
xmllint --noout "$APPCAST"

echo ">> Publishing $DMG_LATEST"
cp "$DMG" "$DMG_LATEST"

# Recorded against the bare filename rather than the path it happened to be built at, so the
# sidecar is usable as `shasum -c SoloDisplay.dmg.sha256` next to a downloaded file.
echo ">> Checksums"
for f in "$ZIP" "$DMG" "$DMG_LATEST"; do
  (cd "$DIST_DIR" && shasum -a 256 "$(basename "$f")" | tee "$(basename "$f").sha256")
done

echo ">> Done. Artifacts in $DIST_DIR"
