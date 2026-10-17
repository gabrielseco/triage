#!/usr/bin/env bash
# The verify_command Workbench runs in a thread's worktree: build this worktree's Triage into a throwaway bundle,
# launch it, and screenshot its window into $WORKBENCH_PROOF_DIR once per `proof: screenshot: <name>` line in the goal.
# The installed ~/Applications/Triage.app (same bundle id, same window name) is never touched: the window is found by
# the PID of the process started here, and only that PID is killed.
#   WORKBENCH_PROOF_DIR  absolute, empty directory for the PNGs (required)
#   WORKBENCH_GOAL       path of the goal file (required)
#   VERIFY_SETTLE_SECONDS  wait after the window appears, for the first refresh (default 15)
# The terminal running this needs Screen Recording permission.
set -euo pipefail

: "${WORKBENCH_PROOF_DIR:?WORKBENCH_PROOF_DIR is not set}"
: "${WORKBENCH_GOAL:?WORKBENCH_GOAL is not set}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

names=()
while IFS= read -r name; do
  [[ -n "$name" ]] && names+=("$name")
done < <(sed -nE 's/^[[:space:]-]*proof:[[:space:]]*screenshot:[[:space:]]*([^[:space:]]+)[[:space:]]*$/\1/p' "$WORKBENCH_GOAL")

if [[ ${#names[@]} -eq 0 ]]; then
  echo "No 'proof: screenshot:' lines in $WORKBENCH_GOAL, nothing to capture."
  exit 0
fi
for name in "${names[@]}"; do
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ && "$name" != .* ]] || { echo "Bad screenshot name: $name" >&2; exit 1; }
done

# Without Screen Recording, screencapture saves a wallpaper-only image instead of failing.
if ! swift - <<'SWIFT'
import CoreGraphics
exit(CGPreflightScreenCaptureAccess() ? 0 : 1)
SWIFT
then
  echo "Screen Recording permission is missing: grant it to this terminal/app in System Settings > Privacy & Security." >&2
  exit 1
fi

# A second process with the installed app's bundle id (dev.rogal.triage) starts but opens no window, so the
# throwaway build gets its own id, and with it its own settings domain, deleted again on exit.
VERIFY_ID="dev.rogal.triage.verify"
TMP="$(mktemp -d)"
LOG="$TMP/triage.log"
PID=""
cleanup() {
  if [[ -n "$PID" ]]; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  defaults delete "$VERIFY_ID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

APP="$TMP/Triage.app"
TRIAGE_APP="$APP" "$ROOT/scripts/bundle.sh" >&2
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $VERIFY_ID" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1  # changing the plist breaks the signature bundle.sh made

# Read-only copy of the installed app's repo list and filters, so the screenshot has something to show. Only
# these keys: the alert state and the secret references stay out, so the pilot cannot notify or ask 1Password.
defaults delete "$VERIFY_ID" 2>/dev/null || true
swift - "$VERIFY_ID" <<'SWIFT' >&2
import Foundation
let target = CommandLine.arguments[1]
let keep = ["repos", "onlyMine", "gitlabHost"]
let source = UserDefaults.standard.persistentDomain(forName: "dev.rogal.triage") ?? [:]
UserDefaults.standard.setPersistentDomain(source.filter { keep.contains($0.key) }, forName: target)
SWIFT

"$APP/Contents/MacOS/Triage" >"$LOG" 2>&1 &
PID=$!

id=""
SECONDS=0  # wall clock: each lookup starts the Swift interpreter, so counting iterations would overrun 60 s
while ((SECONDS < 60)); do
  if ! kill -0 "$PID" 2>/dev/null; then
    break
  fi
  if info="$(swift "$ROOT/scripts/window-info.swift" "$PID" 2>/dev/null)"; then
    read -r id _ <<<"$info"
    break
  fi
  sleep 0.5
done

if [[ -z "$id" ]]; then
  echo "Triage (pid $PID) showed no window within 60 s. End of its output:" >&2
  tail -n 40 "$LOG" >&2
  exit 1
fi

sleep "${VERIFY_SETTLE_SECONDS:-15}"  # the first refresh is a network fetch: the list is empty until it ends
for name in "${names[@]}"; do
  screencapture -x -o -l "$id" "$WORKBENCH_PROOF_DIR/$name.png"
  echo "$WORKBENCH_PROOF_DIR/$name.png"
done
