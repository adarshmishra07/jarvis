#!/usr/bin/env bash
# Builds and installs Jarvis Hands (computer use) in the companion folder. It is ad-hoc signed, and macOS ties the Screen
# Recording and Accessibility permissions to the exact build, so it is only replaced when its code changes: updating Jarvis
# keeps your permissions.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
app="$HOME/Library/Application Support/agent-pikachu/Jarvis Hands.app"
hash="$(shasum -a 256 "$root/hands/main.swift" "$0" | shasum -a 256 | cut -c1-16)"
[ "$(cat "$app/Contents/Resources/source-hash" 2>/dev/null)" = "$hash" ] && { echo "Jarvis Hands is up to date"; exit 0; }
work="$(mktemp -d)"
mkdir -p "$work/Jarvis Hands.app/Contents/MacOS" "$work/Jarvis Hands.app/Contents/Resources"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swiftc -O -swift-version 6 "$root/hands/main.swift" -o "$work/Jarvis Hands.app/Contents/MacOS/JarvisHands"
cp "$root/app/Resources/AppIcon.icns" "$work/Jarvis Hands.app/Contents/Resources/AppIcon.icns"
echo "$hash" > "$work/Jarvis Hands.app/Contents/Resources/source-hash"
cat > "$work/Jarvis Hands.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.agentpikachu.hands</string>
<key>CFBundleExecutable</key><string>JarvisHands</string>
<key>CFBundleName</key><string>Jarvis Hands</string>
<key>CFBundleDisplayName</key><string>Jarvis Hands</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>$hash</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - --identifier dev.agentpikachu.hands "$work/Jarvis Hands.app"
pkill -x JarvisHands 2>/dev/null || true
rm -rf "$app"; mkdir -p "$(dirname "$app")"; mv "$work/Jarvis Hands.app" "$app"; rm -rf "$work"
echo "installed $app (macOS will ask for its permissions again the first time Jarvis uses the screen)"
