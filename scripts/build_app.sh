#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Usage Monitor"
EXECUTABLE_NAME="UsageMonitor"
APP_DIR="$ROOT/outputs/${APP_NAME}.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

cd "$ROOT"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"

cp "$ROOT/.build/release/$EXECUTABLE_NAME" "$MACOS/$EXECUTABLE_NAME"
cp "$ROOT/bridge/claude-statusline-bridge.mjs" "$RESOURCES/claude-statusline-bridge.mjs"
cp "$ROOT/assets/claude-logo.png" "$RESOURCES/claude-logo.png"
cp "$ROOT/assets/codex-logo.png" "$RESOURCES/codex-logo.png"
chmod +x "$MACOS/$EXECUTABLE_NAME" "$RESOURCES/claude-statusline-bridge.mjs"

cp "$ROOT/scripts/Info.plist" "$CONTENTS/Info.plist"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
fi

echo "$APP_DIR"
