#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="${FLIT_APP_PATH:-$ROOT/dist/Flit.app}"
SIGN_IDENTITY="${FLIT_SIGN_IDENTITY:--}"
BUILD_UNIVERSAL="${FLIT_BUILD_UNIVERSAL:-0}"
APP_ICON="${FLIT_APP_ICON:-$ROOT/assets/Flit.icns}"
OAUTH_CONFIG="${FLIT_GOOGLE_OAUTH_CONFIG:-}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [[ "$BUILD_UNIVERSAL" == "1" ]]; then
  BUILD_ROOT="$ROOT/dist/build"
  ARM_SCRATCH="$BUILD_ROOT/arm64"
  INTEL_SCRATCH="$BUILD_ROOT/x86_64"
  rm -rf "$BUILD_ROOT"
  swift build -c release --triple arm64-apple-macosx13.0 --scratch-path "$ARM_SCRATCH"
  swift build -c release --triple x86_64-apple-macosx13.0 --scratch-path "$INTEL_SCRATCH"
  lipo -create \
    "$ARM_SCRATCH/arm64-apple-macosx/release/Flit" \
    "$INTEL_SCRATCH/x86_64-apple-macosx/release/Flit" \
    -output "$APP/Contents/MacOS/Flit"
else
  swift build -c release
  BIN_DIR="$(swift build -c release --show-bin-path)"
  cp "$BIN_DIR/Flit" "$APP/Contents/MacOS/Flit"
fi

cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
if [[ -f "$APP_ICON" ]]; then
  cp "$APP_ICON" "$APP/Contents/Resources/Flit.icns"
fi

if [[ -z "$OAUTH_CONFIG" && -f "$ROOT/Support/GoogleOAuth.local.json" ]]; then
  OAUTH_CONFIG="$ROOT/Support/GoogleOAuth.local.json"
fi
if [[ -n "$OAUTH_CONFIG" ]]; then
  [[ -f "$OAUTH_CONFIG" ]] || {
    printf 'OAuth configuration not found: %s\n' "$OAUTH_CONFIG" >&2
    exit 1
  }
  cp "$OAUTH_CONFIG" "$APP/Contents/Resources/GoogleOAuth.json"
  chmod 0644 "$APP/Contents/Resources/GoogleOAuth.json"
fi

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP" >/dev/null
else
  codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$SIGN_IDENTITY" \
    "$APP"
fi
codesign --verify --deep --strict "$APP"

printf 'Built %s\n' "$APP"
printf 'Architectures: %s\n' "$(lipo -archs "$APP/Contents/MacOS/Flit")"
printf 'Signature: %s\n' "$SIGN_IDENTITY"
