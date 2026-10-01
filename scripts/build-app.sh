#!/usr/bin/env bash
# Builds build/ScratchPad.app (web editor bundle + Swift binary) without needing Xcode.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/ScratchPad.app"

cd "$ROOT/web"
[ -d node_modules ] || npm install --no-audit --no-fund
npm run build --silent

cd "$ROOT"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/ScratchPad"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web"
cp "$BIN" "$APP/Contents/MacOS/ScratchPad"
cp "$ROOT/web/dist/index.html" "$ROOT/web/dist/editor.bundle.js" "$APP/Contents/Resources/web/"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

codesign --force --sign - --timestamp=none "$APP" >/dev/null
echo "Built $APP"
