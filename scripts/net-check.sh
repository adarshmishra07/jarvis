#!/usr/bin/env bash
# Proves the app itself never opens an internet connection: runs it on made-up demo data, asks a question that needs
# the web, watches the app process's sockets, and lists the hosts the companion called (from its ledger).
# Needs /tmp/pk-demo/demo.db (made-up data). Pauses the installed companion while it runs and restarts it after.
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d)"; cp /tmp/pk-demo/demo.db "$work/demo.db"
label="gui/$(id -u)/dev.agentpikachu.companion"
chats="$HOME/Library/Containers/dev.agentpikachu.app/Data/Library/Application Support/chats"
before="$(ls "$chats" 2>/dev/null || true)"
launchctl bootout "$label" 2>/dev/null || true
pkill -x Jarvis || true; sleep 1
PIKACHU_DB="$work/demo.db" PIKACHU_LEDGER="$work/ledger.jsonl" node --env-file=.env --experimental-strip-types companion/src/main.ts > "$work/log" 2>&1 &
companion=$!
cleanup() { # always: stop the demo companion, drop the demo chat, bring the real companion back
  kill "$companion" 2>/dev/null || true; pkill -x Jarvis || true
  for f in $(ls "$chats" 2>/dev/null); do grep -qx "$f" <<< "$before" || rm "${chats:?}/${f:?}"; done
  launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/dev.agentpikachu.companion.plist" 2>/dev/null || true
}
trap cleanup EXIT
sleep 2
open -n app/build/Jarvis.app --args -snapshot ask -snapshotAsk "What is the weather in London right now and what is Asha working on?"
sleep 3; app="$(pgrep -x Jarvis)"; seen=0
for _ in $(seq 1 25); do seen=$((seen + $({ lsof -nP -a -p "$app" -i 2>/dev/null || true; } | tail -n +2 | wc -l))); sleep 1; done
echo "companion called:"; python3 -c "import json,sys; [print('  ' + json.loads(l)['host']) for l in open(sys.argv[1])]" "$work/ledger.jsonl" | sort | uniq -c
if [ "$seen" -eq 0 ]; then echo "PASS: the app opened no internet connections"; else echo "FAIL: the app opened $seen internet sockets"; exit 1; fi
