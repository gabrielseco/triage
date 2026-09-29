#!/usr/bin/env bash
# Build a release .app into ~/Applications (needed for notifications + login item; a bare binary can't use them).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${TRIAGE_APP:-$HOME/Applications/Triage.app}"  # TRIAGE_APP: build elsewhere (/verify)
BUNDLE_ID="dev.rogal.triage"

# Low CPU priority: this runs from /verify and the post-merge hook while the user is working.
nice -n 10 swift build -c release -q --package-path "$ROOT"

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
# Sign with the stable identity from scripts/setup-signing.sh so Keychain "Always Allow" survives rebuilds.
# An ad-hoc signature (the fallback) changes with every build, so Keychain asks again each time.
SIGN_ID="Triage Local Signing"
if ! security find-identity -p codesigning | grep -qF "\"$SIGN_ID\""; then
  echo "warning: no '$SIGN_ID' certificate, signing ad-hoc (Keychain will re-prompt after each rebuild). Run scripts/setup-signing.sh" >&2
  SIGN_ID="-"
fi
codesign --force --sign "$SIGN_ID" "$APP" >/dev/null

# One-time: carry over settings saved by the unbundled binary (domain "Triage").
if ! defaults read "$BUNDLE_ID" repos >/dev/null 2>&1 && defaults read Triage repos >/dev/null 2>&1; then
  defaults export Triage - | defaults import "$BUNDLE_ID" -
fi

echo "$APP"
