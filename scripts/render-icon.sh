#!/usr/bin/env bash
# Re-render Resources/AppIcon.png (1024px, transparent) from AppIcon.svg. Run after editing the SVG.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless --disable-gpu --hide-scrollbars \
  --default-background-color=00000000 --window-size=1024,1024 \
  --screenshot="$ROOT/Resources/AppIcon.png" "file://$ROOT/Resources/AppIcon.svg" 2>/dev/null
echo "$ROOT/Resources/AppIcon.png"
