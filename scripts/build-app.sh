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
model() { # repo, folder in the app: from the download cache, or (once that is cleared) from the installed app
  local from; from="$(ls -d "$hub"/models--mlx-community--"$1"/snapshots/*/ 2>/dev/null | head -1)"
  [ -n "$from" ] || from="/Applications/Jarvis.app/Contents/Resources/models/$2/"
  [ -d "$from" ] || { echo "missing model: run hf download mlx-community/$1"; exit 1; }
  cp -RLc "$from" "$app/Contents/Resources/models/$2"
}
model Qwen3-ASR-0.6B-8bit qwen3-asr
model Kokoro-82M-bf16 kokoro
[ -d "$root/app/models/hf" ] && [ -s "$root/app/models/smart-turn-v3.2-cpu.onnx" ] || bash "$root/scripts/fetch-models.sh"
cp -Rc "$root/app/models/hf" "$app/Contents/Resources/models/hf"
cp -c "$root/app/models/smart-turn-v3.2-cpu.onnx" "$app/Contents/Resources/models/smart-turn.onnx"
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
