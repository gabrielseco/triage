#!/usr/bin/env bash
# Capture Triage's main window for /verify and PR screenshots. The terminal needs Screen Recording permission.
#   scripts/snap.sh out.png        screenshot of the window, no shadow
#   scripts/snap.sh out.mov 10     10-second video of the window's area
set -euo pipefail

out="${1:?usage: scripts/snap.sh <out.png|out.mov> [seconds]}"
info="$(swift "$(dirname "$0")/window-info.swift")" || { echo "No Triage window on screen" >&2; exit 1; }
read -r id x y w h <<<"$info"

if [[ "$out" == *.mov ]]; then
  screencapture -x -v -V "${2:-10}" -R "$x,$y,$w,$h" "$out"
else
  screencapture -x -o -l "$id" "$out"
fi
echo "$out"
