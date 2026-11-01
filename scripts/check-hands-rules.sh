#!/usr/bin/env bash
# Checks that Jarvis Hands matches never.json exactly like the companion does (the shared cases in never.cases.json).
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swiftc -swift-version 6 "$root/hands/rules.swift" "$root/hands/check/main.swift" -o "$work/check"
"$work/check" "$root"
