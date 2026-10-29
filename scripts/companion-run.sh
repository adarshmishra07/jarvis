#!/usr/bin/env bash
# Starts the installed companion with its keys read from the Keychain (service dev.agentpikachu). Used by the LaunchAgent.
# install-launchagent.sh copies this next to the companion code in Application Support, outside the protected Desktop.
set -euo pipefail
home="$HOME/Library/Application Support/agent-pikachu"
key() { security find-generic-password -s dev.agentpikachu -a "$1" -w 2>/dev/null || true; }
export ANTHROPIC_API_KEY="$(key ANTHROPIC_API_KEY)" TYPESAFE_API_KEY="$(key TYPESAFE_API_KEY)"
export TINYFISH_API_KEY="$(key TINYFISH_API_KEY)" FIRECRAWL_API_KEY="$(key FIRECRAWL_API_KEY)" COMPOSIO_API_KEY="$(key COMPOSIO_API_KEY)"
export PIKACHU_DB="$home/memory.db" PIKACHU_GLOSSARY="$home/glossary.json" PIKACHU_SPELLINGS="$home/spellings.json" PIKACHU_ALIASES="$home/aliases.json"
# The node pinned at install time, or, if an upgrade moved it, one in the usual places.
node="${NODE:-}"
for candidate in "$node" /opt/homebrew/bin/node /usr/local/bin/node "$(ls -d "$HOME"/.nvm/versions/node/*/bin/node 2>/dev/null | tail -1)"; do
  [ -n "$candidate" ] && [ -x "$candidate" ] && { node="$candidate"; break; }
done
exec "${node:-node}" --experimental-strip-types "$home/companion/src/main.ts"
