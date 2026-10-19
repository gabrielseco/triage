#!/usr/bin/env bash
# The verify_command Workbench runs in a thread's worktree: build this worktree's Triage into a throwaway bundle,
# launch it on mock data, and screenshot its window into $WORKBENCH_PROOF_DIR once per `proof: screenshot: <name>` line
# in the goal. The app reaches nothing real (docs/plans/MOCK.md): no GitHub, no GitLab, no Keychain, no settings of the
# installed app, so there is nothing to wait for and nothing private in the picture. The installed
# ~/Applications/Triage.app is never touched: the build has its own bundle id, the window is found by the PID of the
# process started for it, and only that PID is killed (scripts/verify-app.sh).
#   WORKBENCH_PROOF_DIR  absolute, empty directory for the PNGs (required)
#   WORKBENCH_GOAL       path of the goal file (required)
#   VERIFY_FIXTURE      the mock scenario (default Mocks/default.json); a goal that needs another state names its file
#   VERIFY_SETTLE_SECONDS  wait after the window appears, for the first refresh (default 3)
#   VERIFY_WINDOW_SIZE  <width>x<height> in points the window is set to before any capture (default 1440x900). The
#                       window opens near the app's minimum, which cuts the sidebar. Needs Accessibility; without it
#                       the capture is at the launch size, with a note.
# A screenshot named <name> is taken after the steps in scripts/verify-steps/<name>.steps, if that file exists: one
# step per line, `press <label>` (scripts/ax.swift, on this build only) or `wait <seconds>`. A name with no steps file
# captures the window as it is. Steps run in the order the goal names the screenshots, each from the state the last left.
# The terminal running this needs Screen Recording permission, and Accessibility when a steps file is used.
set -euo pipefail

: "${WORKBENCH_PROOF_DIR:?WORKBENCH_PROOF_DIR is not set}"
: "${WORKBENCH_GOAL:?WORKBENCH_GOAL is not set}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

FIXTURE="${VERIFY_FIXTURE:-$ROOT/Mocks/default.json}"
[[ -f "$FIXTURE" ]] || { echo "No such mock scenario: $FIXTURE" >&2; exit 1; }
FIXTURE="$(cd "$(dirname "$FIXTURE")" && pwd)/$(basename "$FIXTURE")"

WINDOW_SIZE="${VERIFY_WINDOW_SIZE:-1440x900}"
[[ "$WINDOW_SIZE" =~ ^[1-9][0-9]*x[1-9][0-9]*$ ]] || { echo "Bad VERIFY_WINDOW_SIZE: $WINDOW_SIZE (want <width>x<height>)" >&2; exit 1; }

names=()
while IFS= read -r name; do
  [[ -n "$name" ]] && names+=("$name")
done < <(sed -nE 's/^[[:space:]-]*proof:[[:space:]]*screenshot:[[:space:]]*([^[:space:]]+)[[:space:]]*$/\1/p' "$WORKBENCH_GOAL")

# `workbench doctor` runs this with a stub goal that names nothing; exiting 0 there proves nothing, so it gets one capture
# and exercises the build, the launch and the permissions.
if [[ ${#names[@]} -eq 0 && "${WORKBENCH_THREAD:-}" == "doctor" ]]; then
  names=(doctor)
fi

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

for name in "${names[@]}"; do
  [[ -f "$ROOT/scripts/verify-steps/$name.steps" ]] || continue
  if ! swift - <<'SWIFT'
import ApplicationServices
exit(AXIsProcessTrusted() ? 0 : 1)
SWIFT
  then
    echo "Accessibility permission is missing (needed to press buttons for $name): grant it in System Settings > Privacy & Security." >&2
    exit 1
  fi
  break
done

# The throwaway build, its launch on mock data, the window lookup, the resize and the settle wait are scripts/verify-app.sh
# (shared with the /verify skill under Workbench); this script drives it from the goal. The build has its own bundle id so
# the installed ~/Applications/Triage.app is never touched, and every later call names the pid it printed.
PID=""
cleanup() {
  [[ -n "$PID" ]] && "$ROOT/scripts/verify-app.sh" stop "$PID" >/dev/null 2>&1
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

started="$("$ROOT/scripts/verify-app.sh" start "$FIXTURE")" || exit 1
PID="$(sed -n 's/^pid=//p' <<<"$started")"
[[ "$PID" =~ ^[1-9][0-9]*$ ]] || { echo "verify-app.sh printed no pid" >&2; exit 1; }
echo "window: $(sed -n 's/^size=//p' <<<"$started")"

# A steps file is reviewed in a PR and only has these two verbs. The buttons that act on a forge, open another app or spend
# money are refused by verify-app.sh press even if a file names them: the mock has nothing to lose, but a steps file is also
# read against the real app.
run_steps() {
  local file="$1" verb arg
  while IFS=' ' read -r verb arg || [[ -n "$verb" ]]; do
    case "$verb" in
      '' | '#'*) ;;
      wait)
        [[ "$arg" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "$file: bad wait: $arg" >&2; return 1; }
        sleep "$arg"
        ;;
      press)
        [[ -n "$arg" ]] || { echo "$file: refused step: press" >&2; return 1; }
        "$ROOT/scripts/verify-app.sh" press "$PID" "$arg" >&2 || return 1
        ;;
      *) echo "$file: unknown step: $verb" >&2; return 1 ;;
    esac
  done <"$file"
}

for name in "${names[@]}"; do
  steps="$ROOT/scripts/verify-steps/$name.steps"
  if [[ -f "$steps" ]]; then
    run_steps "$steps" || { echo "The steps for $name failed" >&2; exit 1; }
    sleep 1.5  # SwiftUI animates the change
  fi
  "$ROOT/scripts/verify-app.sh" shot "$PID" "$name"
done
