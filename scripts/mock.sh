#!/usr/bin/env bash
# Open Triage on mock data, to look at a state or try a change: nothing real is reached (docs/plans/MOCK.md).
#   scripts/mock.sh [scenario.json]    default: Mocks/default.json
# Builds a throwaway bundle with its own bundle id, so the installed ~/Applications/Triage.app is never touched, its
# settings are never read, and its Keychain items are never asked for. Quit the app (⌘Q) or press Ctrl-C to finish.
# To write a state of your own, copy Mocks/default.json: times are hours ago, kinds follow from the data.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCENARIO="${1:-$ROOT/Mocks/default.json}"
[[ -f "$SCENARIO" ]] || { echo "No such scenario: $SCENARIO" >&2; exit 1; }
SCENARIO="$(cd "$(dirname "$SCENARIO")" && pwd)/$(basename "$SCENARIO")"

MOCK_ID="dev.rogal.triage.mock"
STATE_DOMAIN="dev.rogal.triage.mock-state"  # MockMode.defaultsSuite: the app's settings and state in mock mode
TMP="$(mktemp -d)"
cleanup() {
  for domain in "$MOCK_ID" "$STATE_DOMAIN"; do
    defaults delete "$domain" 2>/dev/null || true
    rm -f "$HOME/Library/Preferences/$domain.plist"  # `defaults delete` leaves an empty file
  done
  rm -rf "$HOME/Library/Saved Application State/$MOCK_ID.savedState"  # the window frame macOS keeps per bundle id
  rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

APP="$TMP/Triage.app"
TRIAGE_APP="$APP" "$ROOT/scripts/bundle.sh" >&2
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $MOCK_ID" "$APP/Contents/Info.plist"
# Changing the plist breaks the signature bundle.sh made; sign with the same stable identity, as it does.
SIGN_ID="Triage Local Signing"
security find-identity -p codesigning | grep -qF "\"$SIGN_ID\"" || SIGN_ID="-"
codesign --force --sign "$SIGN_ID" "$APP" >/dev/null 2>&1

# A scenario that does not load ends the app at once, and `open` drops its message: check it first.
TRIAGE_FIXTURE="$SCENARIO" "$APP/Contents/MacOS/Triage" --check-fixture >/dev/null || { echo "Not opening: $SCENARIO" >&2; exit 1; }

echo "Triage on mock data: $SCENARIO" >&2
open -n -F -W --env "TRIAGE_FIXTURE=$SCENARIO" "$APP"
