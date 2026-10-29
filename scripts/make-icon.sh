#!/usr/bin/env bash
# Regenerates app/Resources/AppIcon.icns from scripts/make-icon.swift. Edit the Swift file to change the icon.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"; set="$work/AppIcon.iconset"; mkdir "$set"
swift "$root/scripts/make-icon.swift" "$work/icon.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$work/icon.png" --out "$set/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$work/icon.png" --out "$set/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$set" -o "$root/app/Resources/AppIcon.icns"
cp "$work/icon.png" "$root/app/Resources/AppIcon.png"
rm -rf "$work"
echo "$root/app/Resources/AppIcon.icns"
