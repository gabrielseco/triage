#!/usr/bin/env bash
# Build a release .app into ~/Applications (needed for notifications + login item; a bare binary can't use them).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HOME/Applications/Triage.app"
BUNDLE_ID="dev.rogal.triage"

swift build -c release -q --package-path "$ROOT"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/Triage" "$APP/Contents/MacOS/Triage"

# App icon: every size macOS asks for, from the 1024px master (scripts/render-icon.sh makes it from the SVG).
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Triage</string>
  <key>CFBundleDisplayName</key><string>Triage</string>
  <key>CFBundleExecutable</key><string>Triage</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Triage opens iTerm to start your coding agent in a worktree for the PR.</string>
</dict>
</plist>
EOF
codesign --force --sign - "$APP" >/dev/null 2>&1

# One-time: carry over settings saved by the unbundled binary (domain "Triage").
if ! defaults read "$BUNDLE_ID" repos >/dev/null 2>&1 && defaults read Triage repos >/dev/null 2>&1; then
  defaults export Triage - | defaults import "$BUNDLE_ID" -
fi

echo "$APP"
