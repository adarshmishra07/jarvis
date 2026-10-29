#!/usr/bin/env bash
# Builds a new version and stages it for the in-app Update button, without touching the running app.
# The app shows "Update ready" with what changed; pressing Update now installs it (scripts/apply-update.sh).
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
home="$HOME/Library/Application Support/agent-pikachu"
next="$home/staged.new"
[ -e "$home/applying" ] && { echo "an update is being installed right now; try again in a minute"; exit 1; }
[ -d "$repo/companion/node_modules" ] || { echo "companion/node_modules is missing: run npm install in companion first"; exit 1; }
bash "$repo/scripts/build-app.sh" > /dev/null
rm -rf "$next"; mkdir -p "$next/companion"
cp -Rpc "$repo/app/build/Jarvis.app" "$next/Jarvis.app" # clones (copy-on-write), not full copies
rsync -a --exclude '*.test.ts' "$repo/companion/src/" "$next/companion/src/"
rsync -a "$repo/companion/node_modules/" "$next/companion/node_modules/"
cp "$repo/companion/package.json" "$next/companion/package.json"
cp "$repo/scripts/companion-run.sh" "$next/run.sh"
cp "$repo/scripts/apply-update.sh" "$next/apply.sh"
commit="$(bash "$repo/scripts/version.sh")"
installed="$(cat "$home/installed-version" 2>/dev/null | head -1 || true)"
printf '%s\n%s\n' "$commit" "$(date '+%Y-%m-%d %H:%M')" > "$next/version"
# What changed since the installed version: one commit subject per line.
if [ -n "$installed" ] && git -C "$repo" cat-file -e "${installed%%-dirty-*}" 2>/dev/null; then
  git -C "$repo" log --format=%s "${installed%%-dirty-*}..HEAD" > "$next/notes"
  [ "$commit" = "${commit%%-dirty-*}" ] || echo "Uncommitted changes" >> "$next/notes"
else
  git -C "$repo" log --format=%s -10 > "$next/notes"
fi
rm -rf "$home/staged"; mv "$next" "$home/staged"
echo "staged $commit ($(wc -l < "$home/staged/notes" | tr -d ' ') changes)"
