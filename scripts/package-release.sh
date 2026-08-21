#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TAG="${FLIT_RELEASE_TAG:-}"
if [[ -z "$TAG" ]]; then
  TAG="$(git describe --tags --exact-match 2>/dev/null || true)"
fi
[[ "$TAG" == v* ]] || {
  printf 'Set FLIT_RELEASE_TAG or run from an exact v* tag.\n' >&2
  exit 1
}

MARKETING_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)"
ARTIFACT_VERSION="${TAG#v}"
[[ "$ARTIFACT_VERSION" == "$MARKETING_VERSION" || "$ARTIFACT_VERSION" == "$MARKETING_VERSION"-* ]] || {
  printf 'Tag %s does not match Info.plist version %s.\n' "$TAG" "$MARKETING_VERSION" >&2
  exit 1
}

OAUTH_CONFIG="${FLIT_GOOGLE_OAUTH_CONFIG:-}"
[[ -n "$OAUTH_CONFIG" && -f "$OAUTH_CONFIG" ]] || {
  printf 'FLIT_GOOGLE_OAUTH_CONFIG must point to the approved release OAuth JSON.\n' >&2
  exit 1
}
[[ -f "$ROOT/assets/Flit.icns" ]] || {
  printf 'Missing assets/Flit.icns.\n' >&2
  exit 1
}

UNSIGNED="${FLIT_RELEASE_UNSIGNED:-0}"
SIGN_IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
NOTARY_PROFILE="${NOTARYTOOL_PROFILE:-}"
if [[ "$UNSIGNED" != "1" ]]; then
  [[ "$SIGN_IDENTITY" == Developer\ ID\ Application:* ]] || {
    printf 'DEVELOPER_ID_APPLICATION must contain a Developer ID Application identity.\n' >&2
    exit 1
  }
  [[ -n "$NOTARY_PROFILE" ]] || {
    printf 'NOTARYTOOL_PROFILE is required for notarization.\n' >&2
    exit 1
  }
else
  SIGN_IDENTITY="-"
fi

RELEASE_DIR="$ROOT/dist/release"
APP="$ROOT/dist/Flit.app"
STAGING="$ROOT/dist/dmg-staging"
SUFFIX=""
if [[ "$UNSIGNED" == "1" ]]; then SUFFIX="-unsigned"; fi
ZIP="$RELEASE_DIR/Flit-$ARTIFACT_VERSION$SUFFIX.zip"
DMG="$RELEASE_DIR/Flit-$ARTIFACT_VERSION$SUFFIX.dmg"

rm -rf "$RELEASE_DIR" "$STAGING"
mkdir -p "$RELEASE_DIR" "$STAGING"

FLIT_BUILD_UNIVERSAL=1 \
FLIT_SIGN_IDENTITY="$SIGN_IDENTITY" \
FLIT_GOOGLE_OAUTH_CONFIG="$OAUTH_CONFIG" \
FLIT_APP_PATH="$APP" \
  "$ROOT/scripts/build-app.sh"

if [[ "$UNSIGNED" != "1" ]]; then
  PRE_NOTARY_ZIP="$RELEASE_DIR/Flit-notarization-upload.zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$PRE_NOTARY_ZIP"
  xcrun notarytool submit "$PRE_NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  rm -f "$PRE_NOTARY_ZIP"
fi

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
ditto "$APP" "$STAGING/Flit.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create \
  -volname "Flit $MARKETING_VERSION" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$DMG" >/dev/null
rm -rf "$STAGING"

if [[ "$UNSIGNED" != "1" ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type execute --verbose=2 "$APP"
fi

(
  cd "$RELEASE_DIR"
  shasum -a 256 "$(basename "$ZIP")" "$(basename "$DMG")" > SHA256SUMS
)

printf '\nRelease artifacts:\n'
ls -lh "$ZIP" "$DMG" "$RELEASE_DIR/SHA256SUMS"
if [[ "$UNSIGNED" == "1" ]]; then
  printf '\nWARNING: unsigned validation package; do not publish as a public release.\n' >&2
fi
