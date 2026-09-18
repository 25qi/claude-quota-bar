#!/usr/bin/env bash
# Build, bundle as a .app, install into ~/Applications, and launch.
# Re-running is how you update: the old copy is stopped and replaced.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Claude Usage Tide"
DEST="$HOME/Applications/${APP_NAME}.app"

echo "==> Building"
swift build -c release

echo "==> Stopping the running copy, if any"
pkill -f "${APP_NAME}.app/Contents/MacOS/ClaudeUsageTide" 2>/dev/null || true
# Wait for it to actually exit, or `open` below just refocuses the old process.
for _ in $(seq 1 20); do
    pgrep -f "${APP_NAME}.app/Contents/MacOS/ClaudeUsageTide" >/dev/null || break
    sleep 0.25
done

echo "==> Bundling"
./bundle.sh .build/release/ClaudeUsageTide "$DEST"

echo "==> Launching"
open "$DEST"

echo
echo "Installed: $DEST"
echo "On first run macOS asks whether \`security\` may read \"Claude Code-credentials\". Choose \"Always Allow\"."
echo "Then tick \"Launch at Login\" in the menu bar dropdown and forget about it."
