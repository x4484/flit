#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$ROOT/dist/Flit.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Flit" "$APP/Contents/MacOS/Flit"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"

codesign --force --sign - "$APP" >/dev/null
printf 'Built %s\n' "$APP"
