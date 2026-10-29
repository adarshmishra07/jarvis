#!/usr/bin/env bash
# Installs the staged version. Run by the companion (detached, in its own session) when you press Update now.
# The new app is copied beside the old one before anything is removed, so a failure never leaves you without an app.
set -euo pipefail
home="$HOME/Library/Application Support/agent-pikachu"
app=/Applications/Jarvis.app
old=/Applications/Pikachu.app # the name before the rename: removed once Jarvis is in place
label=dev.agentpikachu.companion
plist="$HOME/Library/LaunchAgents/$label.plist"
work="$home/applying"
running() { pgrep -f "^/Applications/(Jarvis|Pikachu)\.app/Contents/MacOS/" > /dev/null; }

# Claim the staged version in one step: a second press, or a new staging, cannot touch this run.
mv "$home/staged" "$work" 2>/dev/null || { echo "nothing staged, or an update is already running"; exit 1; }

# On any failure: put the old app back if it was moved, start the companion, reopen, and leave the update staged.
undo() {
  echo "update failed; restoring"
  [ -d "$app" ] || { [ -d "$app.old" ] && mv "$app.old" "$app"; } || true
  [ -d "$home/companion" ] || { [ -d "$home/companion.old" ] && mv "$home/companion.old" "$home/companion"; } || true
  [ -d "$home/staged" ] || mv "$work" "$home/staged" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null || true
  if [ -d "$app" ]; then open "$app"; elif [ -d "$old" ]; then open "$old"; fi
}
trap undo ERR

rm -rf "$app.new" "$app.old" "$home/companion.new" "$home/companion.old"
cp -Rpc "$work/Jarvis.app" "$app.new" # clones: almost no extra disk space
cp -Rpc "$work/companion" "$home/companion.new"

osascript -e 'tell application id "dev.agentpikachu.app" to quit' 2>/dev/null || true
for _ in $(seq 1 15); do running || break; sleep 1; done
if running; then pkill -f "^/Applications/(Jarvis|Pikachu)\.app/Contents/MacOS/" || true; for _ in $(seq 1 5); do running || break; sleep 1; done; fi

# The companion stops before its files change (this script survives: it runs in its own session).
# Its folder holds only code (data sits beside it), so it is swapped whole and can be put back on failure.
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
mv "$home/companion" "$home/companion.old" 2>/dev/null || true
mv "$home/companion.new" "$home/companion"
mv "$app" "$app.old" 2>/dev/null || true
mv "$app.new" "$app"
cp "$work/run.sh" "$home/run.sh"
rm -rf "$app.old" "$home/companion.old" "$old"
cp "$work/version" "$home/installed-version"
trap - ERR
rm -rf "$work"
# launchd can take a moment to let go of the old companion: try a few times, and reopen the app either way.
for _ in 1 2 3 4 5; do launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null && break; sleep 2; done
open "$app"
echo "installed $(head -1 "$home/installed-version")"
