#!/usr/bin/env bash
# Prints the build environment and exits 1 if a hard requirement is missing.
set -u
fail=0

echo "# Environment"
echo "- date: $(date '+%Y-%m-%d %H:%M')"
macos="$(sw_vers -productVersion)"
echo "- macOS: $macos"
echo "- chip: $(sysctl -n machdep.cpu.brand_string)"
echo "- RAM GB: $(( $(sysctl -n hw.memsize) / 1073741824 ))"

# macOS 14.2+ needed for Core Audio process taps
major="${macos%%.*}"; rest="${macos#*.}"; minor="${rest%%.*}"
if [ "$major" -lt 14 ] || { [ "$major" -eq 14 ] && [ "$minor" -lt 2 ]; }; then
  echo "- MISSING: macOS 14.2+ required"; fail=1
fi

if xcodebuild -version >/dev/null 2>&1; then
  echo "- xcodebuild: $(xcodebuild -version | tr '\n' ' ')"
else
  echo "- MISSING: Xcode (xcodebuild); Metal shaders cannot build with SwiftPM alone"; fail=1
fi

if command -v swift >/dev/null 2>&1; then
  echo "- swift: $(swift --version 2>&1 | head -1)"
else
  echo "- MISSING: swift"; fail=1
fi

if command -v node >/dev/null 2>&1; then
  nv="$(node -v)"; echo "- node: $nv"
  [ "${nv#v}" != "$nv" ] && [ "${nv#v}" -ge 22 ] 2>/dev/null || [ "$(echo "${nv#v}" | cut -d. -f1)" -ge 22 ] || { echo "- MISSING: Node 22+"; fail=1; }
else
  echo "- MISSING: node"; fail=1
fi

if command -v python3 >/dev/null 2>&1; then
  echo "- python: $(python3 --version)"
else
  echo "- MISSING: python3"; fail=1
fi

exit $fail
