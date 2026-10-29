#!/usr/bin/env bash
# Copies the API keys from .env into the login Keychain (service dev.agentpikachu). Never prints a value.
set -euo pipefail
cd "$(dirname "$0")/.."
for key in ANTHROPIC_API_KEY TYPESAFE_API_KEY TINYFISH_API_KEY FIRECRAWL_API_KEY COMPOSIO_API_KEY; do
  value="$(grep -E "^${key}=" .env | head -1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//' || true)"
  if [ -z "$value" ]; then echo "$key: not in .env, skipped"; continue; fi
  security add-generic-password -U -s dev.agentpikachu -a "$key" -w "$value"
  echo "$key: saved to Keychain"
done
