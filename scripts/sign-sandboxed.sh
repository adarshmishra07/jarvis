#!/usr/bin/env bash
# Usage: sign-sandboxed.sh <app> [--with-network]
# Ad-hoc signs an .app with App Sandbox + audio-input and NO network keys.
# --with-network exists only to prove check-entitlements.sh catches a regression.
set -eu
app="${1:?usage: sign-sandboxed.sh <app> [--with-network]}"
extra="${2:-}"

plist="$(mktemp -t pikachu-ents).plist"
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
  echo '<plist version="1.0"><dict>'
  echo '<key>com.apple.security.app-sandbox</key><true/>'
  echo '<key>com.apple.security.device.audio-input</key><true/>'
  echo '<key>com.apple.security.files.user-selected.read-only</key><true/>' # Import: only files you pick
  if [ "$extra" = "--with-network" ]; then
    echo '<key>com.apple.security.network.client</key><true/>'
  fi
  echo '</dict></plist>'
} > "$plist"

codesign --force --deep --sign - --entitlements "$plist" "$app"
rm -f "$plist"
