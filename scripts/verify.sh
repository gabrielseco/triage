#!/usr/bin/env bash
# The verify_command Workbench runs in a thread's worktree: build this worktree's Triage into a throwaway bundle,
# launch it, and screenshot its window into $WORKBENCH_PROOF_DIR once per `proof: screenshot: <name>` line in the goal.
# The installed ~/Applications/Triage.app (same bundle id, same window name) is never touched: the window is found by
# the PID of the process started here, and only that PID is killed.
#   WORKBENCH_PROOF_DIR  absolute, empty directory for the PNGs (required)
#   WORKBENCH_GOAL       path of the goal file (required)
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

TMP="$(mktemp -d)"
LOG="$TMP/triage.log"
PID=""
cleanup() {
  if [[ -n "$PID" ]]; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

APP="$TMP/Triage.app"
TRIAGE_APP="$APP" "$ROOT/scripts/bundle.sh" >&2

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

sleep 2  # let the first render settle
for name in "${names[@]}"; do
  screencapture -x -o -l "$id" "$WORKBENCH_PROOF_DIR/$name.png"
  echo "$WORKBENCH_PROOF_DIR/$name.png"
done
