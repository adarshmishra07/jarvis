#!/usr/bin/env bash
# Installs the companion into Application Support and a LaunchAgent that starts it at login and restarts it if it stops.
# Re-run after changing companion code. Background services cannot read the Desktop, so nothing runs from the repo.
# Undo: launchctl bootout gui/$(id -u)/dev.agentpikachu.companion && rm ~/Library/LaunchAgents/dev.agentpikachu.companion.plist
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
label=dev.agentpikachu.companion
plist="$HOME/Library/LaunchAgents/$label.plist"
logs="$HOME/Library/Logs/agent-pikachu"
node="$(command -v node)" # launchd has a bare PATH, so pin the node in use now
home="$HOME/Library/Application Support/agent-pikachu"
mkdir -p "$logs" "$(dirname "$plist")" "$home/companion"
[ -d "$repo/companion/node_modules" ] || { echo "companion/node_modules is missing: run npm install in companion first"; exit 1; }
# Stop the companion before its files change, and always start it again, even if a copy fails.
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
trap 'launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null || true' EXIT
rsync -a --delete --exclude '*.test.ts' "$repo/companion/src/" "$home/companion/src/"
# Only this Mac's build of the meaning-search runtime (the others are about 200 MB).
rsync -a --delete --exclude 'onnxruntime-node/bin/napi-v6/linux' --exclude 'onnxruntime-node/bin/napi-v6/win32' "$repo/companion/node_modules/" "$home/companion/node_modules/"
# The meaning-search model (multilingual-e5-small, MIT, 118 MB), fetched once and checked against its known hashes.
model="$home/models/multilingual-e5-small"
if [ ! -s "$model/onnx/model_quantized.onnx" ]; then
  mkdir -p "$model/onnx.part"
  base=https://huggingface.co/Xenova/multilingual-e5-small/resolve/main
  for f in tokenizer.json tokenizer_config.json; do curl -sfL "$base/$f" -o "$model/onnx.part/$f" || true; done
  curl -sfL "$base/onnx/model_quantized.onnx" -o "$model/onnx.part/model_quantized.onnx" || true # a failed download is caught by the check below
  if (cd "$model/onnx.part" && printf '%s\n' \
      "f80102d3f2a1229f387d3c81909990d8945513e347b0eab049f7de3c6f98c193  model_quantized.onnx" \
      "0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39  tokenizer.json" \
      "a1d6bc8734a6f635dc158508bef000f8e2e5a759c7d92f984b2c86e5ff53425b  tokenizer_config.json" | shasum -a 256 -c - > /dev/null); then
    mkdir -p "$model/onnx"
    mv "$model/onnx.part/tokenizer.json" "$model/onnx.part/tokenizer_config.json" "$model/"
    mv "$model/onnx.part/model_quantized.onnx" "$model/onnx/"
  else
    echo "meaning-search model download failed its check: memory works by words only"
  fi
  rm -rf "$model/onnx.part"
fi
cp "$repo/companion/package.json" "$home/companion/package.json"
cp "$repo/scripts/companion-run.sh" "$home/run.sh"
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$home/run.sh</string></array>
  <key>EnvironmentVariables</key><dict><key>NODE</key><string>$node</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$logs/companion.log</string>
  <key>StandardErrorPath</key><string>$logs/companion.log</string>
</dict></plist>
PLIST
bash "$repo/scripts/install-hands.sh" || echo "Jarvis Hands (computer use) did not build; everything else works"
trap - EXIT
launchctl bootstrap "gui/$(id -u)" "$plist"
echo "installed: $plist (logs in $logs)"
