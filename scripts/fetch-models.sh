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
du -sh "$hf"/*
