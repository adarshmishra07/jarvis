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
rsync -a --delete "$repo/companion/node_modules/" "$home/companion/node_modules/"
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
trap - EXIT
launchctl bootstrap "gui/$(id -u)" "$plist"
echo "installed: $plist (logs in $logs)"
