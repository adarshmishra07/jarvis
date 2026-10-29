#!/usr/bin/env bash
# Usage: check-entitlements.sh <app-or-binary>
# Exit 1 unless the target is signed, sandboxed, and has no network entitlement.
set -u
target="${1:?usage: check-entitlements.sh <app-or-binary>}"

ents="$(codesign -d --entitlements :- "$target" 2>/dev/null)" || { echo "FAIL: not signed"; exit 1; }
echo "$ents" | grep -q 'com.apple.security.app-sandbox' || { echo "FAIL: app-sandbox entitlement missing"; exit 1; }
if echo "$ents" | grep -q 'com.apple.security.network\.'; then
  echo "FAIL: network entitlement present"; exit 1
fi
echo "PASS: sandboxed, no network entitlement"
