#!/usr/bin/env bash
# Builds the app and installs it as /Applications/Jarvis.app, replacing the old copy. Run it again after every change.
# Memory, chats and settings live in the app's container and the companion folder, so they survive every update.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
app=/Applications/Jarvis.app
bash "$root/scripts/build-app.sh" > /dev/null
# The new app goes beside the old one first, so a failed copy never leaves you without an app.
rm -rf "$app.new"; cp -Rpc "$root/app/build/Jarvis.app" "$app.new"
osascript -e 'tell application id "dev.agentpikachu.app" to quit' 2>/dev/null || true
for _ in $(seq 1 10); do pgrep -f "^/Applications/(Jarvis|Pikachu)\.app/Contents/MacOS/" > /dev/null || break; sleep 1; done
rm -rf "$app.old"; mv "$app" "$app.old" 2>/dev/null || true; mv "$app.new" "$app"; rm -rf "$app.old" /Applications/Pikachu.app
bash "$root/scripts/install-launchagent.sh" > /dev/null # the companion, updated alongside
# The version now installed, for the in-app Update panel.
printf '%s\n%s\n' "$(bash "$root/scripts/version.sh")" "$(date '+%Y-%m-%d %H:%M')" > "$HOME/Library/Application Support/agent-pikachu/installed-version"
rm -rf "$HOME/Library/Application Support/agent-pikachu/staged" # anything staged is older than what was just installed
[ -n "${NO_OPEN:-}" ] || open "$app" # NO_OPEN=1: install without opening Jarvis
echo "installed $app ($(defaults read "$app/Contents/Info" CFBundleVersion))"
