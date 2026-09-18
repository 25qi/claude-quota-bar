#!/usr/bin/env bash
# Build, bundle as a .app, install into ~/Applications, and launch.
# Re-running is how you update: the old copy is stopped and replaced.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Claude Quota Bar"
BUNDLE_ID="com.qi.claude-quota-bar"
DEST="$HOME/Applications/${APP_NAME}.app"

echo "==> Building"
swift build -c release

echo "==> Stopping the running copy, if any"
pkill -f "${APP_NAME}.app/Contents/MacOS/ClaudeQuotaBar" 2>/dev/null || true
# Wait for it to actually exit, or `open` below just refocuses the old process.
for _ in $(seq 1 20); do
    pgrep -f "${APP_NAME}.app/Contents/MacOS/ClaudeQuotaBar" >/dev/null || break
    sleep 0.25
done

echo "==> Bundling"
rm -rf "$DEST"
mkdir -p "$DEST/Contents/MacOS"

cp .build/release/ClaudeQuotaBar "$DEST/Contents/MacOS/ClaudeQuotaBar"

cat > "$DEST/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ClaudeQuotaBar</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <!-- Menu bar only: no Dock icon, no cmd-tab entry. -->
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Signing is required, or SMAppService will refuse to register for login.
echo "==> Signing"
codesign --force --sign - "$DEST" >/dev/null

echo "==> Launching"
open "$DEST"

echo
echo "Installed: $DEST"
echo "On first run macOS asks for keychain access. Choose \"Always Allow\"."
echo "Then tick \"Launch at Login\" in the menu bar dropdown and forget about it."
