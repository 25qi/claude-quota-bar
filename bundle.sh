#!/usr/bin/env bash
# Assemble and sign the .app from an already-built binary.
# Shared by install.sh and the Homebrew formula so both produce the same bundle.
#
#   ./bundle.sh <built-binary> <destination.app> [--homebrew]
#
# --homebrew marks the bundle as managed by `brew services`, which then owns
# launch at login; the app hides its own toggle so it cannot start twice.
set -euo pipefail

BINARY="$1"
DEST="$2"
MANAGED="false"
[ "${3:-}" = "--homebrew" ] && MANAGED="true"

rm -rf "$DEST"
mkdir -p "$DEST/Contents/MacOS"
cp "$BINARY" "$DEST/Contents/MacOS/ClaudeQuotaBar"

cat > "$DEST/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ClaudeQuotaBar</string>
    <key>CFBundleIdentifier</key><string>com.qi.claude-quota-bar</string>
    <key>CFBundleName</key><string>Claude Quota Bar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <!-- Menu bar only: no Dock icon, no cmd-tab entry. -->
    <key>LSUIElement</key><true/>
    <key>CQBManagedByHomebrew</key><${MANAGED}/>
</dict>
</plist>
PLIST

# Signing is required, or SMAppService will refuse to register for login.
# swift build has already ad-hoc signed the binary, so codesign always reports
# "replacing existing signature"; stay quiet on success, show output on failure.
if ! SIGN_OUTPUT=$(codesign --force --sign - "$DEST" 2>&1); then
    echo "$SIGN_OUTPUT" >&2
    exit 1
fi
