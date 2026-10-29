#!/usr/bin/env bash
# Builds app/build/Jarvis.app: Swift release build, bundle, sandbox signing, entitlement check.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/app/build/Jarvis.app"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# xcodebuild, not swift build: MLX needs its Metal shaders compiled into mlx.metallib.
(cd "$root/app" && xcodebuild -scheme Pikachu -destination 'platform=macOS' -configuration Release \
  -derivedDataPath "$root/app/dd" -skipMacroValidation -skipPackagePluginValidation build > "$root/app/xcodebuild.log" 2>&1) \
  || { grep -E "error:" "$root/app/xcodebuild.log" | head -20; exit 1; }
products="$root/app/dd/Build/Products/Release"
rm -rf "$root/app/build"; mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/models"
cp "$products/PikachuApp" "$app/Contents/MacOS/Jarvis"
for b in "$products"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$app/Contents/Resources/"; done
# Geist and Geist Mono (OFL), registered by the app at launch.
mkdir -p "$app/Contents/Resources/Fonts" && cp "$root/app/Sources/PikachuApp/Fonts/"* "$app/Contents/Resources/Fonts/"
cp "$root/app/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
metallib="$(find "$products" -name 'mlx.metallib' -o -name 'default.metallib' | head -1)"
[ -n "$metallib" ] && cp "$metallib" "$app/Contents/MacOS/mlx.metallib"
# Local models, copied as APFS clones (no extra disk). The app never downloads anything.
hub="$HOME/.cache/huggingface/hub"
cp -RLc "$(ls -d "$hub"/models--mlx-community--Qwen3-ASR-0.6B-8bit/snapshots/*/ | head -1)" "$app/Contents/Resources/models/qwen3-asr"
cp -RLc "$(ls -d "$hub"/models--mlx-community--Kokoro-82M-bf16/snapshots/*/ | head -1)" "$app/Contents/Resources/models/kokoro"
[ -d "$root/app/models/hf" ] || bash "$root/scripts/fetch-models.sh"
cp -Rc "$root/app/models/hf" "$app/Contents/Resources/models/hf"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.agentpikachu.app</string>
<key>CFBundleExecutable</key><string>Jarvis</string>
<key>CFBundleName</key><string>Jarvis</string>
<key>CFBundleDisplayName</key><string>Jarvis</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>$(date +%Y%m%d.%H%M)</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSAudioCaptureUsageDescription</key><string>While Jarvis takes notes, it also records the Mac's sound so the other side of a call is in the transcript. Audio never leaves the Mac.</string>
<key>NSMicrophoneUsageDescription</key><string>Jarvis listens when you talk to it (the hotkey, TALK, "Hey Jarvis") and while it takes notes. Audio never leaves the Mac.</string>
</dict></plist>
PLIST
bash "$root/scripts/sign-sandboxed.sh" "$app"
bash "$root/scripts/check-entitlements.sh" "$app"
echo "$app"
