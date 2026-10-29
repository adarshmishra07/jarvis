#!/usr/bin/env bash
# The version of the code in this repo: the commit, plus a time stamp when there are uncommitted changes, so a build of
# local edits always counts as new. Used by install-app.sh and stage-update.sh.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
commit="$(git -C "$repo" rev-parse --short=12 HEAD)"
if [ -n "$(git -C "$repo" status --porcelain --untracked-files=no)" ]; then echo "$commit-dirty-$(date +%s)"; else echo "$commit"; fi
