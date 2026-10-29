#!/usr/bin/env bash
# One-time, outside the sandbox: puts the speech front-end files where mlx-audio-swift looks for them,
# so the sandboxed app never needs the network. Speech models themselves come from the local HF cache.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
hf="$root/app/models/hf/mlx-audio"
get() { # repo file
  local dir="$hf/${1/\//_}"; mkdir -p "$dir"
  [ -s "$dir/$2" ] || curl -sfL "https://huggingface.co/$1/resolve/main/$2" -o "$dir/$2"
}
for f in us_bart.safetensors us_bart_config.json us_gold.json us_silver.json; do get beshkenadze/kitten-tts-g2p "$f"; done
# The library re-downloads a cached model that has no config.json, so give it a valid empty one.
[ -f "$hf/beshkenadze_kitten-tts-g2p/config.json" ] || echo '{}' > "$hf/beshkenadze_kitten-tts-g2p/config.json"
for f in config.json model.safetensors; do get beshkenadze/g2p-multilingual-byT5-tiny-mlx "$f"; done
# Smart Turn v3.2 (BSD-2): tells a finished sentence from a pause mid-thought. Checked against its known hash.
turn="$root/app/models/smart-turn-v3.2-cpu.onnx"
if [ ! -s "$turn" ]; then
  curl -sfL https://huggingface.co/pipecat-ai/smart-turn-v3/resolve/main/smart-turn-v3.2-cpu.onnx -o "$turn.part"
  echo "2bb026316b14a660486a75b1733cd3fbab8c2fd0314dc9af7be49f8cca967e4f  $turn.part" | shasum -a 256 -c - > /dev/null && mv "$turn.part" "$turn"
fi
du -sh "$hf"/* "$turn"
